--!strict
-- The only place damage is dealt. A request runs through ordered policies
-- (each may change the amount; reaching 0 blocks the hit and names the
-- policy), then TakeDamage on the target humanoid. Applied damage is
-- announced through Damaged / Killed, and recent attackers are remembered per
-- target for assists.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Signal = require(ReplicatedStorage.packages.Signal)

local Config = require(ReplicatedStorage.shared.config)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)

type PlayerSession = PlayerSession.PlayerSession

local INVULNERABLE_ATTRIBUTE = Config.World.Attributes.Invulnerable

export type Combatant = { Model: Model, Player: Player? }

export type DamageRequest = {
	Source: Combatant,
	Target: Model,
	Amount: number,
	Kind: "Melee",
	WeaponId: string,
	MoveId: number,
	Position: Vector3,
}

-- Returns the new amount and an optional note. An amount of 0 (or less)
-- blocks the request; Apply then reports the policy's name as the reason.
export type Policy = (request: DamageRequest, amount: number) -> (number, string?)

export type DamageConfig = {
	FriendlyFire: boolean,
	SpawnProtectionSeconds: number,
	RecentAttackerWindow: number,
	RecentAttackerCount: number,
	AllowUntaggedHumanoidTargets: boolean,
}

export type WorldTags = { Damageable: string, [string]: string }

export type DamageServiceDeps = {
	players: PlayerService.PlayerService,
	scheduler: Scheduler.Scheduler,
	config: DamageConfig,
	tags: WorldTags,
}

-- Reasons Apply returns besides policy names.
local NOT_DAMAGEABLE = "NotDamageable"
local INVALID_REQUEST = "InvalidRequest"
-- TakeDamage changed nothing (a ForceField, or health already at 0).
local NO_EFFECT = "NoEffect"

type CharacterInfo = { Player: Player, SpawnedAt: number }

type AttackerEntry = { Source: Combatant, At: number }

type TargetRecord = { Entries: { AttackerEntry }, Connections: { RBXScriptConnection } }

type NamedPolicy = { Name: string, Policy: Policy }

type DamageServiceFields = {
	Trove: PlayerSession.Trove,
	-- Vendored GoodSignal is untyped.
	-- Damaged fires (request: DamageRequest, applied: number, health_after: number).
	Damaged: any,
	-- Killed fires (request: DamageRequest, assists: { Combatant }).
	Killed: any,
	_config: DamageConfig,
	_tags: WorldTags,
	_scheduler: Scheduler.Scheduler,
	_policies: { NamedPolicy },
	_characters: { [Model]: CharacterInfo },
	_recent: { [Model]: TargetRecord },
	_destroyed: boolean,
}

local DamageService = {}
DamageService.__index = DamageService

export type DamageService = typeof(setmetatable({} :: DamageServiceFields, DamageService))

local function is_positive_finite(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value ~= math.huge
end

function DamageService.new(deps: DamageServiceDeps): DamageService
	Deps.check(deps, "DamageService", { "players", "scheduler", "config", "tags" })

	local fields: DamageServiceFields = {
		Trove = Trove.new(),
		Damaged = Signal.new(),
		Killed = Signal.new(),
		_config = deps.config,
		_tags = deps.tags,
		_scheduler = deps.scheduler,
		_policies = {},
		_characters = {},
		_recent = {},
		_destroyed = false,
	}
	local self = setmetatable(fields, DamageService)

	self.Trove:Add(self.Damaged)
	self.Trove:Add(self.Killed)

	self:AddPolicy("Invulnerable", function(request, amount)
		if request.Target:GetAttribute(INVULNERABLE_ATTRIBUTE) == true then
			return 0, nil
		end
		return amount, nil
	end)

	self:AddPolicy("SpawnProtection", function(request, amount)
		local seconds = self._config.SpawnProtectionSeconds
		local info = self._characters[request.Target]
		if seconds > 0 and info and self._scheduler.clock() - info.SpawnedAt < seconds then
			return 0, nil
		end
		return amount, nil
	end)

	self:AddPolicy("Team", function(request, amount)
		if self._config.FriendlyFire then
			return amount, nil
		end
		local source_player = request.Source.Player
		local info = self._characters[request.Target]
		local target_player = info and info.Player
		if source_player and target_player and source_player ~= target_player then
			local source_team: Team? = source_player.Team
			if source_team
				and source_player.Neutral == false
				and target_player.Neutral == false
				and source_team == target_player.Team then
				return 0, nil
			end
		end
		return amount, nil
	end)

	-- Extension point: a "Block" policy (a defending stance) belongs here,
	-- registered by the service that owns blocking.

	deps.players:Register(self, "DamageService")

	return self
end

-- Adds a policy after the existing ones. Names are unique.
function DamageService.AddPolicy(self: DamageService, name: string, policy: Policy)
	if type(name) ~= "string" or name == "" or type(policy) ~= "function" then
		error("DamageService:AddPolicy: expected (name: string, policy: function)", 2)
	end
	for _, existing in self._policies do
		if existing.Name == name then
			error(("DamageService:AddPolicy: duplicate policy '%s'"):format(name), 2)
		end
	end
	table.insert(self._policies, { Name = name, Policy = policy })
end

function DamageService.OnCharacterAdded(self: DamageService, session: PlayerSession, character: Model)
	self._characters[character] = { Player = session.Player, SpawnedAt = self._scheduler.clock() }
end

function DamageService.OnCharacterRemoving(self: DamageService, _session: PlayerSession, character: Model)
	self._characters[character] = nil
	self:_forget(character)
end

-- The player whose current character this is, if any.
function DamageService.GetPlayer(self: DamageService, model: Model): Player?
	local info = self._characters[model]
	return info and info.Player
end

-- An alive humanoid model (the model itself, not a model nested inside one)
-- that is a player character, is tagged Damageable, or is any humanoid model
-- while AllowUntaggedHumanoidTargets is on.
function DamageService.IsDamageable(self: DamageService, model: Model): (boolean, Humanoid?)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return false, nil
	end
	local resolved, humanoid = CharacterQuery.resolve_alive(model)
	if resolved ~= model or humanoid == nil then
		return false, nil
	end
	if self._characters[model] ~= nil
		or CollectionService:HasTag(model, self._tags.Damageable)
		or self._config.AllowUntaggedHumanoidTargets then
		return true, humanoid
	end
	return false, nil
end

-- Requests are checked at runtime as well, so callers outside the type checker
-- (or with partial tables) cannot reach TakeDamage with a malformed request.
local function is_valid_request(request: any): boolean
	return type(request) == "table"
		and type(request.Source) == "table"
		and typeof(request.Source.Model) == "Instance"
		and typeof(request.Target) == "Instance"
		and is_positive_finite(request.Amount)
end

-- Applies the request. Returns the damage actually dealt (0 when blocked or
-- without effect) and, when 0, the reason: a policy name, NotDamageable,
-- InvalidRequest or NoEffect.
function DamageService.Apply(self: DamageService, request: DamageRequest): (number, string?)
	if self._destroyed or not is_valid_request(request) then
		return 0, INVALID_REQUEST
	end

	local damageable, humanoid = self:IsDamageable(request.Target)
	if not damageable or humanoid == nil then
		return 0, NOT_DAMAGEABLE
	end

	local amount = request.Amount
	for _, entry in self._policies do
		local next_amount = entry.Policy(request, amount)
		if not is_positive_finite(next_amount) then
			return 0, entry.Name
		end
		amount = next_amount
	end

	local before = humanoid.Health
	humanoid:TakeDamage(amount)
	local after = humanoid.Health
	local applied = math.max(before - after, 0)
	if applied <= 0 then
		return 0, NO_EFFECT
	end

	self:_remember(request.Target, request.Source)
	self.Damaged:Fire(request, applied, after)

	if after <= 0 then
		local assists = {}
		for _, combatant in self:GetRecentAttackers(request.Target) do
			if combatant.Model ~= request.Source.Model then
				table.insert(assists, combatant)
			end
		end
		self.Killed:Fire(request, assists)
	end

	return applied, nil
end

local function prune(entries: { AttackerEntry }, now: number, window: number)
	for index = #entries, 1, -1 do
		if now - entries[index].At > window then
			table.remove(entries, index)
		end
	end
end

function DamageService._remember(self: DamageService, target: Model, source: Combatant)
	local record = self._recent[target]
	if record == nil then
		record = { Entries = {}, Connections = {} }
		self._recent[target] = record
		-- Non-player targets have no removal hook; drop their record when
		-- they are destroyed or leave the DataModel (an unparented NPC, for
		-- example one returned to a pool, is never destroyed).
		table.insert(record.Connections, target.Destroying:Connect(function()
			self:_forget(target)
		end))
		table.insert(record.Connections, target.AncestryChanged:Connect(function()
			if not target:IsDescendantOf(game) then
				self:_forget(target)
			end
		end))
	end

	local now = self._scheduler.clock()
	local entries = record.Entries
	prune(entries, now, self._config.RecentAttackerWindow)
	for index = #entries, 1, -1 do
		if entries[index].Source.Model == source.Model then
			table.remove(entries, index)
		end
	end
	table.insert(entries, { Source = source, At = now })
	while #entries > self._config.RecentAttackerCount do
		table.remove(entries, 1)
	end
end

function DamageService._forget(self: DamageService, target: Model)
	local record = self._recent[target]
	if record == nil then
		return
	end
	self._recent[target] = nil
	for _, connection in record.Connections do
		connection:Disconnect()
	end
end

-- Distinct attackers of `target` within RecentAttackerWindow, newest first,
-- at most RecentAttackerCount.
function DamageService.GetRecentAttackers(self: DamageService, target: Model): { Combatant }
	local record = self._recent[target]
	if record == nil then
		return {}
	end
	local now = self._scheduler.clock()
	local window = self._config.RecentAttackerWindow
	local result = {}
	for index = #record.Entries, 1, -1 do
		local entry = record.Entries[index]
		if now - entry.At <= window then
			table.insert(result, entry.Source)
		end
	end
	return result
end

function DamageService.Destroy(self: DamageService)
	if self._destroyed then
		return
	end
	self._destroyed = true
	local targets = {}
	for target in self._recent do
		table.insert(targets, target)
	end
	for _, target in targets do
		self:_forget(target)
	end
	table.clear(self._characters)
	self.Trove:Destroy()
end

return DamageService
