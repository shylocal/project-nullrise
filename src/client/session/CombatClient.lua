--!strict
-- Session-lifetime Combat remote client. It is the only listener on the
-- Combat and CombatFx remotes, so queued events are never split between
-- per-character handlers and subscribers (UI, CombatController) survive respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(script.Parent.Parent.ClientTrove)
local Signal = require(ReplicatedStorage.packages.Signal)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

export type ClientRemoteLike = {
	OnClientEvent: any,
	FireServer: (self: any, ...any) -> (),
}

export type Deps = {
	remote: ClientRemoteLike,
	fx_remote: ClientRemoteLike,
}

type Trove = Trove.Trove
type Signal = typeof(Signal.new())

type CombatClientFields = {
	Remote: ClientRemoteLike,
	FxRemote: ClientRemoteLike,
	Trove: Trove,
	-- (move_id, next_combo_move_id)
	AttackAccepted: Signal,
	-- (move_id?, next_combo_move_id?)
	AttackRejected: Signal,
	-- (move_id, target?)
	HitConfirmed: Signal,
	-- (victim, source?, weapon_id, move_id, position, amount): any nearby hit.
	FxHit: Signal,
	-- (amount, source?): the local character was hit.
	Damaged: Signal,
	_destroyed: boolean,
}

local CombatClient = {}
CombatClient.__index = CombatClient

export type CombatClient = typeof(setmetatable({} :: CombatClientFields, CombatClient))

local function is_index(value: any): boolean
	return typeof(value) == "number" and value == value and math.floor(value) == value
end

local function is_model(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Model")
end

local function is_finite_vector3(value: any): boolean
	return typeof(value) == "Vector3" and math.isfinite(value.X) and math.isfinite(value.Y) and math.isfinite(value.Z)
end

local function is_finite_number(value: any): boolean
	return typeof(value) == "number" and math.isfinite(value)
end

-- The local player's current character, or nil (always nil outside a client).
local function local_character(): Model?
	local player = Players.LocalPlayer
	return player and player.Character
end

function CombatClient.new(deps: Deps): CombatClient
	Deps.check(deps, "CombatClient", { "remote", "fx_remote" })

	local self = setmetatable({
		Remote = deps.remote,
		FxRemote = deps.fx_remote,
		Trove = Trove.new(),
		AttackAccepted = Signal.new(),
		AttackRejected = Signal.new(),
		HitConfirmed = Signal.new(),
		FxHit = Signal.new(),
		Damaged = Signal.new(),
		_destroyed = false,
	} :: CombatClientFields, CombatClient)

	self.Trove:Add(self.AttackAccepted)
	self.Trove:Add(self.AttackRejected)
	self.Trove:Add(self.HitConfirmed)
	self.Trove:Add(self.FxHit)
	self.Trove:Add(self.Damaged)
	self.Trove:Connect(deps.remote.OnClientEvent, function(action: any, ...: any)
		self:_on_event(action, ...)
	end)
	self.Trove:Connect(deps.fx_remote.OnClientEvent, function(action: any, ...: any)
		self:_on_fx_event(action, ...)
	end)

	return self
end

-- Remote payloads are untrusted, so every argument is `any` until checked.
function CombatClient._on_event(self: CombatClient, action: any, move_id: any, value: any)
	if self._destroyed then
		return
	end

	if action == Protocol.Combat.AttackAccepted then
		if is_index(move_id) and is_index(value) then
			self.AttackAccepted:Fire(move_id, value)
		end
	elseif action == Protocol.Combat.AttackRejected then
		if (move_id == nil or is_index(move_id)) and (value == nil or is_index(value)) then
			self.AttackRejected:Fire(move_id, value)
		end
	elseif action == Protocol.Combat.HitConfirmed then
		if is_index(move_id) and (value == nil or is_model(value)) then
			self.HitConfirmed:Fire(move_id, value)
		end
	end
end

function CombatClient._on_fx_event(
	self: CombatClient,
	action: any,
	victim: any,
	source: any,
	weapon_id: any,
	move_id: any,
	position: any,
	amount: any
)
	if self._destroyed or action ~= Protocol.CombatFx.Hit then
		return
	end

	if not is_model(victim)
		or (source ~= nil and not is_model(source))
		or typeof(weapon_id) ~= "string"
		or not is_index(move_id)
		or not is_finite_vector3(position)
		or not is_finite_number(amount) then
		return
	end

	self.FxHit:Fire(victim, source, weapon_id, move_id, position, amount)

	local character = local_character()
	if character ~= nil and victim == character then
		self.Damaged:Fire(amount, source)
	end
end

function CombatClient.Send(self: CombatClient, action: string, ...: any)
	if self._destroyed then
		return
	end
	self.Remote:FireServer(action, ...)
end

function CombatClient.Destroy(self: CombatClient)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
end

return CombatClient
