local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Hitbox = require(script.Parent.Hitbox)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local CombatRemote = ReplicatedStorage.remotes.Combat

local AttackLifecycle = {}

function AttackLifecycle.begin_attack(self, attack_key, attack, track, remote_action)
	AttackLifecycle.clear_attack_lifecycle(self)

	self.Charging = attack_key == "Charge"
	self.ChargeReady = false
	self.CurrentAttackKey = attack_key
	self.CurrentTrack = track

	self.MovementController:SetSprintBlocked(
		not AttackLifecycle.can_sprint_while_attacking(self, attack),
		self
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

			CombatRemote:FireServer(Protocol.Combat.HitStart, attack_key)
			AttackLifecycle.start_hitbox(self, attack_key, attack)
		end
	)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStop"),
		function()
			AttackLifecycle.stop_hitbox(self)
			CombatRemote:FireServer(Protocol.Combat.HitStop, attack_key)
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
		if self.BufferedAttack and self.PrimaryHeld then
			AttackInput.resolve_buffered_attack(self)
		end
	end)
end
function AttackLifecycle.clear_attack_lifecycle(self)
	local attack_key = self.CurrentAttackKey
	if attack_key then
		CombatRemote:FireServer(Protocol.Combat.HitStop, attack_key)
	end

	AttackLifecycle.stop_hitbox(self)

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
function AttackLifecycle.can_sprint_while_attacking(self, attack)
	local weapon = self.WeaponController.Equipped

	if attack.CanSprintWhileAttacking ~= nil then
		return attack.CanSprintWhileAttacking
	end

	return weapon and weapon.CanSprintWhileAttacking == true
end
function AttackLifecycle.start_hitbox(self, attack_key, attack)
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
				Protocol.Combat.Hit,
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
function AttackLifecycle.stop_hitbox(self)
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

return AttackLifecycle
