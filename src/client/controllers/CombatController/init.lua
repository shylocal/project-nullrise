local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local AttackLifecycle = require(script.AttackLifecycle)
local AttackInput = require(script.AttackInput)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local CombatController = {}
CombatController.__index = CombatController

function CombatController.new(deps)
	Deps.check(deps, "CombatController", { "weapon", "animation", "state", "input", "combat", "scheduler" })

	local self = setmetatable({
		Trove = Trove.new(),
		WeaponController = deps.weapon,
		AnimationController = deps.animation,
		State = deps.state,
		CombatClient = deps.combat,
		Scheduler = deps.scheduler,

		AttackTrove = nil,
		AttackLifecycleId = 0,
		AttackLease = nil,
		Hitbox = nil,

		NextAttack = 1,
		PendingAttackIndex = nil,
		PendingAttackId = 0,
		CurrentAttackKey = nil,
		CurrentTrack = nil,

		ChargeReady = false,

		BufferedAttack = nil,
		AttackReadyAt = 0,

		Charging = false,
		PrimaryHeld = false,
		PrimaryPressId = 0,
		PrimaryPressAttackPending = false,

		_destroyed = false,
	}, CombatController)

	local ok, err = pcall(self._start, self, deps.input)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CombatController:_start(input_controller)
	self.Trove:Connect(
		self.CombatClient.AttackAccepted,
		function(attack_key, next_index)
			if attack_key ~= self.PendingAttackIndex then
				return
			end

			local weapon = self.WeaponController.Equipped
			if not weapon or not weapon.Attacks or not weapon.Attacks[next_index] then
				return
			end

			self.NextAttack = next_index
			self.PendingAttackIndex = nil
		end
	)

	self.Trove:Connect(
		self.CombatClient.AttackRejected,
		function(attack_key, next_index)
			if self.PendingAttackIndex == attack_key then
				self.PendingAttackIndex = nil
				if typeof(next_index) == "number" then
					self.NextAttack = next_index
				end
			end
		end
	)

	self.Trove:Connect(
		input_controller.ActionBegan,
		function(action)
			if action == Actions.Primary then
				AttackInput.primary_began(self)
			end
		end
	)

	self.Trove:Connect(
		input_controller.ActionEnded,
		function(action)
			if action == Actions.Primary then
				AttackInput.primary_ended(self)
			end
		end
	)
end

function CombatController:_is_alive()
	local humanoid = self.WeaponController.Character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function CombatController:Attack()
	if self.PendingAttackIndex ~= nil or not self:_can_begin_attack() then
		return
	end

	if not self.State:CanStart("Attack") or not self:_is_alive() then
		return
	end

	local weapon = self.WeaponController.Equipped
	if not weapon or not weapon.Attacks then
		return
	end

	local attack_index = self.NextAttack
	local attack = weapon.Attacks[attack_index]

	if not attack then
		self.NextAttack = 1
		return
	end

	local cooldown = attack.Cooldown
	if typeof(cooldown) ~= "number" or not math.isfinite(cooldown) or cooldown <= 0 then
		return
	end

	local track = self.AnimationController.Combat:BeginAttack(attack_index)
	if not track then
		return
	end

	-- The server is authoritative over combo sequencing. Keep this request
	-- pending until AttackAccepted/AttackRejected arrives instead of advancing
	-- locally. The server always answers, but a lost or dropped reply must not
	-- block light attacks forever, so give up after PendingAttackTimeout. A late
	-- reply is then ignored and the next request resyncs the combo index.
	self.PendingAttackIndex = attack_index
	self.PendingAttackId += 1
	local pending_attack_id = self.PendingAttackId
	self.Scheduler.after(Config.Combat.PendingAttackTimeout, function()
		if self.PendingAttackId == pending_attack_id then
			self.PendingAttackIndex = nil
		end
	end)

	AttackLifecycle.begin_attack(self, attack_index, attack, track, Protocol.Combat.Attack)
end

function CombatController:Charge()
	if not self:_can_begin_attack() then
		return
	end

	if not self.State:CanStart("Charge") or not self:_is_alive() then
		return
	end

	local weapon = self.WeaponController.Equipped
	local charge = weapon and weapon.Charge
	if not charge then
		return
	end

	local cooldown = charge.Cooldown
	if typeof(cooldown) ~= "number" or not math.isfinite(cooldown) or cooldown <= 0 then
		return
	end

	local track = self.AnimationController.Combat:BeginCharge()
	if not track then
		return
	end

	AttackLifecycle.begin_attack(self, "Charge", charge, track, Protocol.Combat.Charge)
end

function CombatController:_can_begin_attack()
	return self.Scheduler.clock() >= self.AttackReadyAt
end

function CombatController:_resolve_buffered_attack()
	AttackInput.resolve_buffered_attack(self)
end

function CombatController:_release_charge()
	AttackInput.release_charge(self)
end

function CombatController:_finish_attack(attack_key, attack_trove)
	if self.AttackTrove ~= attack_trove then
		return
	end

	AttackLifecycle.stop_hitbox(self)
	self.CombatClient:Send(Protocol.Combat.HitStop, attack_key)

	self.AttackTrove = nil
	self.Trove:Remove(attack_trove)

	self.Charging = false
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	AttackLifecycle.release_lease(self)

	if self.BufferedAttack then
		task.defer(function()
			if not self._destroyed then
				self:_resolve_buffered_attack()
			end
		end)
	end
end

function CombatController:Reset()
	self.AttackLifecycleId += 1
	self.PrimaryHeld = false
	self.PrimaryPressId += 1
	self.PrimaryPressAttackPending = false
	self.BufferedAttack = nil

	AttackLifecycle.clear_attack_lifecycle(self)

	self.AnimationController:StopAction()
	AttackLifecycle.release_lease(self)

	-- Character death and weapon swaps reset through here, so a pending
	-- attack from the previous weapon or character never blocks new input.
	self.NextAttack = 1
	self.PendingAttackIndex = nil
	self.PendingAttackId += 1
	self.AttackReadyAt = 0
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.Charging = false
end

function CombatController:Destroy()
	if self._destroyed then
		return
	end
	self:Reset()
	self._destroyed = true
	self.Trove:Destroy()
end

return CombatController
