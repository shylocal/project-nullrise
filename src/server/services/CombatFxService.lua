--!strict
-- Turns applied damage into client hit effects over the CombatFx
-- UnreliableRemoteEvent: the victim's player always gets the event, and so
-- does every player whose character root is within RelevanceRadius of the hit.
-- Effects are cosmetic, so losing one is harmless.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local ROOT_PART = Config.World.Names.RootPart

export type UnreliableRemoteLike = {
	FireClient: (self: any, player: any, ...any) -> (),
}

export type CombatFxServiceDeps = {
	damage: any,
	players: any,
	remote: UnreliableRemoteLike,
	config: { RelevanceRadius: number },
}

type CombatFxServiceFields = {
	Trove: any,
	_damage: any,
	_players: any,
	_remote: UnreliableRemoteLike,
	_radius: number,
}

local CombatFxService = {}
CombatFxService.__index = CombatFxService

export type CombatFxService = typeof(setmetatable({} :: CombatFxServiceFields, CombatFxService))

function CombatFxService.new(deps: CombatFxServiceDeps): CombatFxService
	Deps.check(deps, "CombatFxService", { "damage", "players", "remote", "config" })

	local fields: CombatFxServiceFields = {
		Trove = Trove.new(),
		_damage = deps.damage,
		_players = deps.players,
		_remote = deps.remote,
		_radius = deps.config.RelevanceRadius,
	}
	local self = setmetatable(fields, CombatFxService)

	self.Trove:Connect(deps.damage.Damaged, function(request: any, applied: number)
		self:_on_damaged(request, applied)
	end)

	return self
end

local function root_position(character: Model?): Vector3?
	local root = character and character:FindFirstChild(ROOT_PART)
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- Players that should see a hit at `position` on `victim`.
function CombatFxService.Recipients(self: CombatFxService, victim: Model, position: Vector3): { any }
	local recipients = {}
	local seen = {}
	local victim_player = self._damage:GetPlayer(victim)
	if victim_player and self._players:GetReady(victim_player) then
		seen[victim_player] = true
		table.insert(recipients, victim_player)
	end

	for _, session in self._players:GetSessions() do
		local player = session.Player
		if seen[player] or session.Phase ~= "Ready" then
			continue
		end
		local root = root_position(session.Character)
		if root and (root - position).Magnitude <= self._radius then
			seen[player] = true
			table.insert(recipients, player)
		end
	end
	return recipients
end

function CombatFxService._on_damaged(self: CombatFxService, request: any, applied: number)
	if applied <= 0 then
		return
	end
	local victim = request.Target
	local source = request.Source and request.Source.Model
	for _, player in self:Recipients(victim, request.Position) do
		self._remote:FireClient(
			player,
			Protocol.CombatFx.Hit,
			victim,
			source,
			request.WeaponId,
			request.MoveId,
			request.Position,
			applied
		)
	end
end

function CombatFxService.Destroy(self: CombatFxService)
	self.Trove:Destroy()
end

return CombatFxService
