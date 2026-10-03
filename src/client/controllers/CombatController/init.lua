local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local AttackLifecycle = require(script.AttackLifecycle)
local AttackInput = require(script.AttackInput)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local CombatRemote = ReplicatedStorage.remotes.Combat

local CombatController = {}
CombatController.__index = CombatController

function CombatController.new(
	weapon_controller,
	animation_controller,
	movement_controller,
	input_controller
)
	local self = setmetatable({
		Trove = Trove.new(),
		WeaponController = weapon_controller,
		AnimationController = animation_controller,
		MovementController = movement_controller,

		AttackTrove = nil,
		AttackLifecycleId = 0,
		Hitbox = nil,

		NextAttack = 1,
		PendingAttackIndex = nil,
		CurrentAttackKey = nil,
		CurrentTrack = nil,

		ChargeReady = false,

		BufferedAttack = nil,
		AttackReadyAt = 0,

		Charging = false,
		PrimaryHeld = false,
		PrimaryPressId = 0,
		PrimaryPressAttackPending = false,

		Hit = Signal.new(),
	}, CombatController)

	self.Trove:Add(self.Hit)
	local ok, err = pcall(self._start, self, input_controller)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CombatController:_start(input_controller)
	self.Trove:Connect(
		CombatRemote.OnClientEvent,
		function(action, attack_key, value)
			if action == Protocol.Combat.AttackAccepted then
				if typeof(attack_key) ~= "number"
					or attack_key ~= self.PendingAttackIndex
					or typeof(value) ~= "number" then
					return
				end

				local weapon = self.WeaponController.Equipped
				if not weapon or not weapon.Attacks or not weapon.Attacks[value] then
					return
				end

				self.NextAttack = value
				self.PendingAttackIndex = nil
			elseif action == Protocol.Combat.HitConfirmed then
				self.Hit:Fire(value)
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

function CombatController:Attack()
	if self.PendingAttackIndex ~= nil or not self:_can_begin_attack() then
		return
	end

	local humanoid = self.WeaponController.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
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
	-- pending until AttackAccepted arrives instead of advancing locally.
	self.PendingAttackIndex = attack_index
	AttackLifecycle.begin_attack(self, attack_index, attack, track, Protocol.Combat.Attack)
end

function CombatController:Charge()
	if not self:_can_begin_attack() then
		return
	end

	local humanoid = self.WeaponController.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
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
	return os.clock() >= self.AttackReadyAt
end

function CombatController:_resolve_buffered_attack()
	AttackInput.resolve_buffered_attack(self)
end

function CombatController:_finish_attack(attack_key, attack_trove)
	if self.AttackTrove ~= attack_trove then
		return
	end

	AttackLifecycle.stop_hitbox(self)
	CombatRemote:FireServer(Protocol.Combat.HitStop, attack_key)

	self.AttackTrove = nil
	self.Trove:Remove(attack_trove)

	self.Charging = false
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.MovementController:SetSprintBlocked(false, self)

	if self.BufferedAttack then
		task.defer(function()
			self:_resolve_buffered_attack()
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
	self.MovementController:SetSprintBlocked(false, self)

	self.NextAttack = 1
	self.PendingAttackIndex = nil
	self.AttackReadyAt = 0
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.Charging = false
end

function CombatController:Destroy()
	self:Reset()
	self.Trove:Destroy()
end

return CombatController
