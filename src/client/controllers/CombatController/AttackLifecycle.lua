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

function AttackLifecycle.is_charge(move)
	return move ~= nil and move.Kind == "Charge"
end

function AttackLifecycle.begin_attack(self, move, track)
	AttackLifecycle.clear_attack_lifecycle(self)

	self.AttackLifecycleId += 1
	local lifecycle_id = self.AttackLifecycleId
	local move_id = move.Id
	local is_charge = AttackLifecycle.is_charge(move)

	self.Charging = is_charge
	self.ChargeReady = false
	self.CurrentMoveId = move_id
	self.CurrentMove = move
	self.CurrentTrack = track

	-- A rooted move blocks sprint through the CharacterState policy.
	AttackLifecycle.release_lease(self)
	local activity = if AttackLifecycle.can_sprint_while_attacking(self, move) then "Attack" else "AttackRooted"
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

			-- While a charge is still held, pause on the marker and wait for
			-- the release. Once released, the marker starts the hit.
			if is_charge and self.Charging and self.PrimaryHeld then
				self.ChargeReady = true
				self.AnimationController.Combat:Pause(track)
				return
			end

			self.CombatClient:Send(Protocol.Combat.HitStart, move_id)
			AttackLifecycle.start_hitbox(self, move, attack_trove, lifecycle_id)
		end
	)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStop"),
		function()
			if not AttackLifecycle.is_current_attack(self, attack_trove, lifecycle_id) then
				return
			end

			AttackLifecycle.stop_hitbox(self)
			self.CombatClient:Send(Protocol.Combat.HitStop, move_id)
		end
	)

	self.CombatClient:Send(Protocol.Combat.Attack, move_id)

	self.AnimationController.Combat:Play(
		track,
		move.Animation.TransitionTime
	)

	-- Cooldown is validated to be no shorter than the server-enforced
	-- MinDuration, so a legitimate client never starts a move early.
	local cooldown = move.Cooldown
	self.AttackReadyAt = self.Scheduler.clock() + cooldown

	-- Owned by the attack trove so a track that never ends (for example one
	-- destroyed by a weapon swap) cannot keep a waiting thread alive.
	attack_trove:Connect(
		track.Ended,
		function()
			-- Tracks are cached and reused, so a late Ended from an earlier
			-- Stop must not finish a move that replayed the same track.
			if track.IsPlaying then
				return
			end
			self:_finish_attack(move_id, attack_trove)
		end
	)

	if is_charge then
		-- The server stops accepting the charge's HitStart after MaxHoldTime,
		-- so release it automatically instead of letting a long hold whiff.
		self.Scheduler.after(move.Hold.MaxHoldTime, function()
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

		if self.BufferedMove and self.PrimaryHeld then
			self:_resolve_buffered_attack()
		end
	end)
end

function AttackLifecycle.clear_attack_lifecycle(self)
	local move_id = self.CurrentMoveId
	if move_id then
		self.CombatClient:Send(Protocol.Combat.HitStop, move_id)
	end

	AttackLifecycle.stop_hitbox(self)

	local attack_trove = self.AttackTrove
	self.AttackTrove = nil

	if attack_trove then
		self.Trove:Remove(attack_trove)
	end

	self.CurrentMoveId = nil
	self.CurrentMove = nil
	self.CurrentTrack = nil
	self.Charging = false
	self.ChargeReady = false
end

function AttackLifecycle.can_sprint_while_attacking(self, move)
	local weapon = self.WeaponController.Equipped

	if move.CanSprintWhileAttacking ~= nil then
		return move.CanSprintWhileAttacking
	end

	return weapon ~= nil and weapon.CanSprintWhileAttacking == true
end

-- Sends a hit from `hitbox` for the move it was last started for. Hits that
-- arrive after that move ended are dropped.
local function forward_hit(self, hitbox, hit_character, raycast_result, segment_instance)
	local owner = self.HitboxOwners[hitbox]
	if not owner or not AttackLifecycle.is_current_attack(self, owner.AttackTrove, owner.LifecycleId) then
		return
	end

	self.CombatClient:Send(
		Protocol.Combat.Hit,
		owner.MoveId,
		hit_character,
		segment_instance,
		raycast_result.Position
	)
end

-- The reusable hitbox for a wielded part: created on first use per equip and
-- part, then only started and stopped. Entries whose part left the character
-- are destroyed here; Reset destroys the rest (weapon swap, death, teardown).
function AttackLifecycle.hitbox_for(self, wielded)
	local character = self.WeaponController.Character
	for part, cached in pairs(self.Hitboxes) do
		if part ~= wielded and not part:IsDescendantOf(character) then
			self.Hitboxes[part] = nil
			self.HitboxOwners[cached] = nil
			cached:Destroy()
		end
	end

	local hitbox = self.Hitboxes[wielded]
	if hitbox then
		return hitbox
	end

	hitbox = Hitbox.new(character, wielded, function(hit_character, raycast_result, segment_instance)
		forward_hit(self, hitbox, hit_character, raycast_result, segment_instance)
	end)
	self.Hitboxes[wielded] = hitbox
	return hitbox
end

function AttackLifecycle.start_hitbox(self, move, expected_trove, expected_lifecycle_id)
	if self.ActiveHit then
		return
	end

	local wielded = self.WeaponController:GetWielded(move.Hitbox)
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

	local hitbox = AttackLifecycle.hitbox_for(self, wielded)
	local owner = {
		Hitbox = hitbox,
		MoveId = move.Id,
		AttackTrove = attack_trove,
		LifecycleId = lifecycle_id,
	}
	self.ActiveHit = owner
	self.HitboxOwners[hitbox] = owner
	hitbox:Start()
end

function AttackLifecycle.stop_hitbox(self)
	local active = self.ActiveHit
	self.ActiveHit = nil

	if active then
		active.Hitbox:Stop()
	end
end

-- Destroys every cached hitbox. Called on weapon swap, death and teardown.
function AttackLifecycle.destroy_hitboxes(self)
	AttackLifecycle.stop_hitbox(self)

	local hitboxes = self.Hitboxes
	self.Hitboxes = {}
	table.clear(self.HitboxOwners)
	for _, hitbox in pairs(hitboxes) do
		hitbox:Destroy()
	end
end

return AttackLifecycle
