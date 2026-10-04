--!strict
-- Session-lifetime Combat remote client. It is the only listener on the
-- Combat and CombatFx remotes, so queued events are never split between
-- per-character handlers and subscribers (UI, CombatController) survive respawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
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

local CombatClient = {}
CombatClient.__index = CombatClient

local function is_index(value: any): boolean
	return typeof(value) == "number" and value == value and math.floor(value) == value
end

-- Attack keys are an attack index or the "Charge" key in Phase 1.
local function is_attack_key(value: any): boolean
	return is_index(value) or value == "Charge"
end

local function is_model(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Model")
end

function CombatClient.new(deps: Deps)
	Deps.check(deps, "CombatClient", { "remote", "fx_remote" })

	local self = setmetatable({
		Remote = deps.remote,
		-- Accepted now so the boot wiring does not change when Phase 2 adds FX.
		FxRemote = deps.fx_remote,
		Trove = Trove.new(),
		AttackAccepted = Signal.new(),
		AttackRejected = Signal.new(),
		HitConfirmed = Signal.new(),
		_destroyed = false,
	}, CombatClient)

	self.Trove:Add(self.AttackAccepted)
	self.Trove:Add(self.AttackRejected)
	self.Trove:Add(self.HitConfirmed)
	self.Trove:Connect(deps.remote.OnClientEvent, function(action: any, ...: any)
		self:_on_event(action, ...)
	end)

	return self
end

function CombatClient:_on_event(action: any, attack_key: any, value: any)
	if self._destroyed then
		return
	end

	if action == Protocol.Combat.AttackAccepted then
		if is_index(attack_key) and is_index(value) then
			self.AttackAccepted:Fire(attack_key, value)
		end
	elseif action == Protocol.Combat.AttackRejected then
		if (attack_key == nil or is_attack_key(attack_key)) and (value == nil or is_index(value)) then
			self.AttackRejected:Fire(attack_key, value)
		end
	elseif action == Protocol.Combat.HitConfirmed then
		if is_attack_key(attack_key) and (value == nil or is_model(value)) then
			self.HitConfirmed:Fire(attack_key, value)
		end
	end
end

function CombatClient:Send(action: string, ...: any)
	if self._destroyed then
		return
	end
	self.Remote:FireServer(action, ...)
end

function CombatClient:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
end

return CombatClient
