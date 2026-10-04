local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local AttackLifecycle = require(script.Parent.AttackLifecycle)

local AttackInput = {}

-- The weapon's Primary Hold move (a Charge move), or nil.
function AttackInput.hold_move(weapon)
	local name = weapon and weapon.Bindings.Primary.Hold
	return name and weapon.Moves[name]
end

function AttackInput.primary_began(self)
	self.PrimaryHeld = true
	self.PrimaryPressId += 1

	local press_id = self.PrimaryPressId
	local weapon = self.WeaponController.Equipped
	if not weapon then
		self.PrimaryPressAttackPending = false
		return
	end

	-- A new mouse press always starts a new input decision. It does not
	-- immediately become a tap just because the previous move was a
	-- released charge. Holding past HoldTime turns this press into the hold
	-- move; releasing before then turns it into the tap.
	if self.Charging then
		self.PrimaryPressAttackPending = false
		return
	end

	local hold_move = AttackInput.hold_move(weapon)
	if hold_move then
		self.PrimaryPressAttackPending = true
		AttackInput.buffer_hold(self, press_id, hold_move)
		return
	end

	self.PrimaryPressAttackPending = false
	self:Attack()
end

function AttackInput.buffer_hold(self, press_id, hold_move)
	self.Scheduler.after(hold_move.Hold.HoldTime, function()
		if self.PrimaryPressId ~= press_id or not self.PrimaryHeld then
			return
		end

		-- Once the hold threshold is crossed, this press has become a hold
		-- intent. Releasing it must never fall back to the tap, even if the
		-- hold move is still waiting for cooldown.
		self.PrimaryPressAttackPending = false
		self.BufferedMove = hold_move.Name
		AttackInput.resolve_buffered_attack(self)
	end)
end

function AttackInput.primary_ended(self)
	self.PrimaryHeld = false
	self.PrimaryPressId += 1

	-- A buffered hold move is cancelled by releasing the input.
	self.BufferedMove = nil

	if not self.Charging then
		if self.PrimaryPressAttackPending then
			self.PrimaryPressAttackPending = false
			self:Attack()
		end
		return
	end

	AttackInput.release_charge(self)
end

-- Releases the active charge: when its HitStart marker was already reached the
-- hit starts now, otherwise the resumed animation reaches the marker and the
-- hit starts there. Called on input release and when MaxHoldTime is reached.
function AttackInput.release_charge(self)
	if not self.Charging then
		return
	end

	local track = self.CurrentTrack
	local charge_ready = self.ChargeReady
	local move = self.CurrentMove
	self.Charging = false

	if charge_ready and move then
		self.ChargeReady = false
		self.CombatClient:Send(Protocol.Combat.HitStart, move.Id)
		AttackLifecycle.start_hitbox(self, move)
	end

	if track then
		self.AnimationController.Combat:Resume(track)
	end
end

function AttackInput.resolve_buffered_attack(self)
	if self.BufferedMove == nil then
		return
	end

	if not self.PrimaryHeld then
		self.BufferedMove = nil
		return
	end

	if not self:_can_begin_attack() then
		return
	end

	self.BufferedMove = nil
	self:Charge()
end

return AttackInput
