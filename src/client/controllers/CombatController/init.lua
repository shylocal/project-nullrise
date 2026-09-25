local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local Hitbox = require(script.Hitbox)

local Actions = require(ReplicatedStorage.shared.input.Actions)

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
		Hitbox = nil,

		NextAttack = 1,
		CurrentAttackKey = nil,
		CurrentTrack = nil,

		ChargeReady = false,

		BufferedAttack = nil,
		AttackToken = 0,
		AttackReadyAt = 0,

		Attacking = false,
		Charging = false,
		PrimaryHeld = false,
		PrimaryPressId = 0,
		PrimaryPressAttackPending = false,

		Hit = Signal.new(),
	}, CombatController)

	self.Trove:Add(self.Hit)
	self:_start(input_controller)

	return self
end

function CombatController:_start(input_controller)
	self.Trove:Connect(
		input_controller.ActionBegan,
		function(action)
			if action == Actions.Primary then
				self:_primary_began()
			end
		end
	)

	self.Trove:Connect(
		input_controller.ActionEnded,
		function(action)
			if action == Actions.Primary then
				self:_primary_ended()
			end
		end
	)
end

function CombatController:_primary_began()
	self.PrimaryHeld = true
	self.PrimaryPressId += 1
	self.PrimaryPressAttackPending = true

	local press_id = self.PrimaryPressId
	local weapon = self.WeaponController.Equipped

	if not weapon then
		self.PrimaryPressAttackPending = false
		return
	end

	-- A charge that has already been released is no longer a charging input.
	-- Once its cooldown has elapsed, a new press may immediately begin the
	-- next light attack even though the old charge animation is still playing.
	if self.Attacking and not self.Charging and self.CurrentAttackKey == "Charge" then
		if self:_can_begin_attack() then
			self.PrimaryPressAttackPending = false
			self:Attack()
			return
		end
	end

	local charge = weapon.Charge
	if not charge then
		if self:_can_begin_attack() then
			self.PrimaryPressAttackPending = false
			self:Attack()
		end
		return
	end

	self:_buffer_charge(press_id, charge)
end

function CombatController:_buffer_charge(press_id, charge)
	local hold_time = charge.HoldTime or 0.15

	task.delay(hold_time, function()
		if self.PrimaryPressId ~= press_id or not self.PrimaryHeld then
			return
		end

		self.BufferedAttack = "Charge"
		self:_resolve_buffered_attack()
	end)
end

function CombatController:_primary_ended()
	self.PrimaryHeld = false
	self.PrimaryPressId += 1

	if self.BufferedAttack == "Charge" then
		self.BufferedAttack = nil
	end

	if not self.Charging then
		if self.PrimaryPressAttackPending then
			self.PrimaryPressAttackPending = false
			self:Attack()
		end
		return
	end

	local track = self.CurrentTrack
	if self.ChargeReady then
		local weapon = self.WeaponController.Equipped
		local charge = weapon and weapon.Charge

		if charge then
			self.ChargeReady = false
			self.Charging = false
			CombatRemote:FireServer("HitStart", "Charge")
			self:_start_hitbox("Charge", charge)
		end
	end

	if track then
		self.AnimationController:Resume(track)
	end
end

function CombatController:Attack()
	if not self:_can_begin_attack() then
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

	self.NextAttack = attack_index == #weapon.Attacks and 1 or attack_index + 1

	self:_begin_attack(attack_index, attack, track, "Attack")
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

	self:_begin_attack("Charge", charge, track, "Charge")
end

function CombatController:_can_begin_attack()
	return os.clock() >= self.AttackReadyAt
end

function CombatController:_begin_attack(attack_key, attack, track, remote_action)
	self.AttackToken += 1
	local attack_token = self.AttackToken

	self:_clear_attack_lifecycle()

	self.Attacking = true
	self.Charging = attack_key == "Charge"
	self.ChargeReady = false
	self.CurrentAttackKey = attack_key
	self.CurrentTrack = track

	self.MovementController:SetSprintBlocked(
		not self:_can_sprint_while_attacking(attack)
	)

	local attack_trove = Trove.new()
	self.AttackTrove = attack_trove
	self.Trove:Add(attack_trove)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStart"),
		function()
			if attack_key == "Charge" and self.PrimaryHeld then
				self.ChargeReady = true
				self.AnimationController.Combat:Pause(track)
				return
			end

			CombatRemote:FireServer("HitStart", attack_key)
			self:_start_hitbox(attack_key, attack)
		end
	)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStop"),
		function()
			self:_stop_hitbox()
			CombatRemote:FireServer("HitStop", attack_key)
		end
	)

	CombatRemote:FireServer(remote_action, attack_key)

	self.AnimationController.Combat:Play(
		track,
		attack.Animation.TransitionTime or 0
	)

	local cooldown = attack.Cooldown
	self.AttackReadyAt = os.clock() + cooldown

	task.spawn(function()
		track.Ended:Wait()
		self:_finish_attack(attack_key, attack_trove)
	end)

	task.delay(cooldown, function()
		if self.AttackToken ~= attack_token then
			return
		end

		if self.BufferedAttack and self.PrimaryHeld then
			self:_resolve_buffered_attack()
		end
	end)
end

function CombatController:_finish_attack(attack_key, attack_trove)
	if self.AttackTrove ~= attack_trove then
		return
	end

	self:_stop_hitbox()
	CombatRemote:FireServer("HitStop", attack_key)

	self.AttackTrove = nil
	self.Trove:Remove(attack_trove)

	self.Attacking = false
	self.Charging = false
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.MovementController:SetSprintBlocked(false)

	if self.BufferedAttack then
		task.defer(function()
			self:_resolve_buffered_attack()
		end)
	end
end

function CombatController:_clear_attack_lifecycle()
	local attack_key = self.CurrentAttackKey
	if attack_key then
		CombatRemote:FireServer("HitStop", attack_key)
	end

	self:_stop_hitbox()

	local attack_trove = self.AttackTrove
	self.AttackTrove = nil

	if attack_trove then
		self.Trove:Remove(attack_trove)
	end

	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.Charging = false
	self.ChargeReady = false
end

function CombatController:_resolve_buffered_attack()
	if self.BufferedAttack ~= "Charge" then
		return
	end

	if not self.PrimaryHeld then
		self.BufferedAttack = nil
		return
	end

	if not self:_can_begin_attack() then
		return
	end

	self.BufferedAttack = nil
	self:Charge()
end

function CombatController:_can_sprint_while_attacking(attack)
	local weapon = self.WeaponController.Equipped

	if attack.CanSprintWhileAttacking ~= nil then
		return attack.CanSprintWhileAttacking
	end

	return weapon and weapon.CanSprintWhileAttacking == true
end

function CombatController:_start_hitbox(attack_key, attack)
	if self.Hitbox then
		return
	end

	local wielded = self.WeaponController:GetWielded(attack.Hitbox)
	if not wielded then
		return
	end

	local attack_trove = self.AttackTrove
	if not attack_trove then
		return
	end

	local hitbox = Hitbox.new(
		self.WeaponController.Character,
		wielded,
		function(hit_character, raycast_result, segment_instance)
			self.Hit:Fire(hit_character, raycast_result)

			CombatRemote:FireServer(
				"Hit",
				attack_key,
				hit_character,
				segment_instance,
				raycast_result.Position
			)
		end
	)

	self.Hitbox = hitbox
	attack_trove:Add(hitbox)
	hitbox:Start()
end

function CombatController:_stop_hitbox()
	local hitbox = self.Hitbox
	self.Hitbox = nil

	if not hitbox then
		return
	end

	hitbox:Stop()

	if self.AttackTrove then
		self.AttackTrove:Remove(hitbox)
	else
		hitbox:Destroy()
	end
end

function CombatController:Reset()
	self.PrimaryHeld = false
	self.PrimaryPressId += 1
	self.PrimaryPressAttackPending = false
	self.AttackToken += 1
	self.BufferedAttack = nil

	local attack_key = self.CurrentAttackKey
	if attack_key then
		CombatRemote:FireServer("HitStop", attack_key)
	end

	self:_stop_hitbox()

	if self.AttackTrove then
		self.Trove:Remove(self.AttackTrove)
		self.AttackTrove = nil
	end

	self.AnimationController:StopAction()
	self.MovementController:SetSprintBlocked(false)

	self.NextAttack = 1
	self.AttackReadyAt = 0
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.Attacking = false
	self.Charging = false
end

function CombatController:Destroy()
	self:Reset()
	self.Trove:Destroy()
end

return CombatController
