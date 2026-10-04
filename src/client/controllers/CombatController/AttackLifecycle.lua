local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Hitbox = require(script.Parent.Hitbox)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local AttackLifecycle = {}

function AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id)
	return self.AttackTrove == attack_trove and self.AttackLifecycleId == lifecycle_id
end

function AttackLifecycle.release_lease(self)
	local lease = self.AttackLease
	self.AttackLease = nil

	if lease then
		lease:Release()
	end
end

function AttackLifecycle.begin_attack(self, attack_key, attack, track, remote_action)
	AttackLifecycle.clear_attack_lifecycle(self)

	self.AttackLifecycleId += 1
	local lifecycle_id = self.AttackLifecycleId

	self.Charging = attack_key == "Charge"
	self.ChargeReady = false
	self.CurrentAttackKey = attack_key
	self.CurrentTrack = track

	-- A rooted attack blocks sprint through the CharacterState policy.
	AttackLifecycle.release_lease(self)
	local activity = if AttackLifecycle.can_sprint_while_attacking(self, attack) then "Attack" else "AttackRooted"
	self.AttackLease = self.State:Acquire(self, activity)

	local attack_trove = Trove.new()
	self.AttackTrove = attack_trove
	self.Trove:Add(attack_trove)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStart"),
		function()
			if not AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id) then
				return
			end

			-- While the charge is still held, pause on the marker and wait
			-- for the release. Once released, the marker starts the hit.
			if attack_key == "Charge" and self.Charging and self.PrimaryHeld then
				self.ChargeReady = true
				self.AnimationController.Combat:Pause(track)
				return
			end

			self.CombatClient:Send(Protocol.Combat.HitStart, attack_key)
			AttackLifecycle.start_hitbox(self, attack_key, attack, attack_trove, lifecycle_id)
		end
	)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStop"),
		function()
			if not AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id) then
				return
			end

			AttackLifecycle.stop_hitbox(self)
			self.CombatClient:Send(Protocol.Combat.HitStop, attack_key)
		end
	)

	self.CombatClient:Send(remote_action, attack_key)

	self.AnimationController.Combat:Play(
		track,
		attack.Animation.TransitionTime
	)

	-- Cooldown is validated to be no shorter than the server-enforced
	-- MinDuration, so a legitimate client never starts an attack early.
	local cooldown = attack.Cooldown
	self.AttackReadyAt = self.Scheduler.clock() + cooldown

	-- Owned by the attack trove so a track that never ends (for example one
	-- destroyed by a weapon swap) cannot keep a waiting thread alive.
	attack_trove:Connect(
		track.Ended,
		function()
			-- Tracks are cached and reused, so a late Ended from an earlier
			-- Stop must not finish an attack that replayed the same track.
			if track.IsPlaying then
				return
			end
			self:_finish_attack(attack_key, attack_trove)
		end
	)

	if attack_key == "Charge" then
		-- The server stops accepting the charge's HitStart after MaxHoldTime,
		-- so release it automatically instead of letting a long hold whiff.
		self.Scheduler.after(attack.MaxHoldTime, function()
			if self.AttackLifecycleId ~= lifecycle_id or not self.Charging then
				return
			end

			self:_release_charge()
		end)
	end

	self.Scheduler.after(cooldown, function()
		if self.AttackLifecycleId ~= lifecycle_id then
			return
		end

		if self.BufferedAttack and self.PrimaryHeld then
			self:_resolve_buffered_attack()
		end
	end)
end

function AttackLifecycle.clear_attack_lifecycle(self)
	local attack_key = self.CurrentAttackKey
	if attack_key then
		self.CombatClient:Send(Protocol.Combat.HitStop, attack_key)
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

	return weapon ~= nil and weapon.CanSprintWhileAttacking == true
end

function AttackLifecycle.start_hitbox(self, attack_key, attack, expected_trove, expected_lifecycle_id)
	if self.Hitbox then
		return
	end

	local wielded = self.WeaponController:GetWielded(attack.Hitbox)
	if not wielded then
		return
	end

	local attack_trove = self.AttackTrove
	local lifecycle_id = expected_lifecycle_id or self.AttackLifecycleId
	if not attack_trove
		or (expected_trove and attack_trove ~= expected_trove)
		or lifecycle_id == nil
		or not AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id) then
		return
	end

	local hitbox = Hitbox.new(
		self.WeaponController.Character,
		wielded,
		function(hit_character, raycast_result, segment_instance)
			if not AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id) then
				return
			end

			self.CombatClient:Send(
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
