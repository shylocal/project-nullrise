local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local Hitbox = require(script.Hitbox)

local Actions = require(ReplicatedStorage.shared.input.Actions)

local CombatRemote = ReplicatedStorage.remotes.Combat

local CombatController = {}
CombatController.__index = CombatController

local ATTACK_BUFFER_WINDOW = 0.1

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

		BufferedAttack = false,
		BufferedAt = 0,

		Attacking = false,
		Charging = false,
		PrimaryHeld = false,
		PrimaryBeganAt = 0,
		PrimaryToken = 0,
		BufferedToken = 0,

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
	self.PrimaryBeganAt = os.clock()
	self.PrimaryToken += 1

	if self.Attacking then
		if not self.Charging and self:_can_buffer_attack() then
			self.BufferedAttack = true
			self.BufferedAt = self.PrimaryBeganAt
			self.BufferedToken = self.PrimaryToken
		end

		return
	end

	local weapon = self.WeaponController.Equipped
	if not weapon then
		return
	end

	local charge = weapon.Charge
	if not charge then
		self:Attack()
		return
	end

	local token = self.PrimaryToken
	local hold_time = charge.HoldTime or 0.15

	task.delay(hold_time, function()
		if self.PrimaryToken ~= token or not self.PrimaryHeld or self.Attacking then
			return
		end

		self:Charge()
	end)
end

function CombatController:_primary_ended()
	self.PrimaryHeld = false
	self.PrimaryToken += 1

	if self.Charging then
		local track = self.CurrentTrack

		if self.ChargeReady then
			local weapon = self.WeaponController.Equipped
			local charge = weapon and weapon.Charge

			if charge then
				self.ChargeReady = false
				self:_start_hitbox("Charge", charge)
				CombatRemote:FireServer("HitStart", "Charge")
			end
		end

		if track then
			self.AnimationController:Resume(track)
		end

		return
	end

	if not self.Attacking then
		self:Attack()
	end
end

function CombatController:Attack()
	if self.Attacking then
		self.BufferedAttack = true
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

	local track = self.AnimationController.Combat:BeginAttack(attack_index)
	if not track then
		return
	end

	self.NextAttack = attack_index == #weapon.Attacks and 1 or attack_index + 1

	self:_begin_attack(attack_index, attack, track, "Attack")
end

function CombatController:Charge()
	if self.Attacking then
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

	local track = self.AnimationController.Combat:BeginCharge()
	if not track then
		return
	end

	self:_begin_attack("Charge", charge, track, "Charge")
end

function CombatController:_begin_attack(attack_key, attack, track, remote_action)
	self.Attacking = true
	self.Charging = attack_key == "Charge"
	self.BufferedAttack = false
	self.CurrentAttackKey = attack_key
	self.CurrentTrack = track
	self.ChargeReady = false

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

			self:_start_hitbox(attack_key, attack)
			CombatRemote:FireServer("HitStart", attack_key)
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

	task.spawn(function()
		track.Ended:Wait()
		self:_finish_attack(attack_key, attack_trove)
	end)
end

function CombatController:_finish_attack(attack_key, attack_trove)
	self:_stop_hitbox()
	CombatRemote:FireServer("HitStop", attack_key)

	if self.AttackTrove ~= attack_trove then
		return
	end

	self.AttackTrove = nil
	self.Trove:Remove(attack_trove)

	self.Attacking = false
	self.Charging = false
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.MovementController:SetSprintBlocked(false)

	if self.BufferedAttack then
		self.BufferedAttack = false

		local token = self.BufferedToken
		local buffered_at = self.BufferedAt
		local weapon = self.WeaponController.Equipped
		local charge = weapon and weapon.Charge

		if self.PrimaryHeld and charge then
			local hold_time = charge.HoldTime or 0.15
			local remaining = hold_time - (os.clock() - buffered_at)

			if remaining <= 0 then
				self:Charge()
			else
				task.delay(remaining, function()
					if self.PrimaryToken ~= token or not self.PrimaryHeld or self.Attacking then
						return
					end

					self:Charge()
				end)
			end
		else
			self:Attack()
		end
	end
end

function CombatController:_can_buffer_attack()
	local track = self.CurrentTrack
	if not track then
		return false
	end

	local time_length = track.Length
	if time_length <= 0 then
		return false
	end

	return time_length - track.TimePosition <= ATTACK_BUFFER_WINDOW
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
	self.PrimaryBeganAt = 0
	self.PrimaryToken += 1

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
	self.CurrentAttackKey = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.BufferedAttack = false
	self.BufferedAt = 0
	self.BufferedToken = 0
	self.Attacking = false
	self.Charging = false
	self.BufferedAttack = false
end

function CombatController:Destroy()
	self:Reset()
	self.Trove:Destroy()
end

return CombatController
