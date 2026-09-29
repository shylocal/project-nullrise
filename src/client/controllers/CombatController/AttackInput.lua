local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local CombatRemote = ReplicatedStorage.remotes.Combat
local AttackLifecycle = require(script.Parent.AttackLifecycle)

local AttackInput = {}

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
	-- immediately become a light attack just because the previous attack was
	-- a released charge. Holding past HoldTime turns this press into charge;
	-- releasing before then turns it into light attack.
	if self.Charging then
		self.PrimaryPressAttackPending = false
		return
	end

	local charge = weapon.Charge
	if charge then
		self.PrimaryPressAttackPending = true
		AttackInput.buffer_charge(self, press_id, charge)
		return
	end

	self.PrimaryPressAttackPending = false
	self:Attack()
end
function AttackInput.buffer_charge(self, press_id, charge)
	local hold_time = charge.HoldTime or 0.15

	task.delay(hold_time, function()
		if self.PrimaryPressId ~= press_id or not self.PrimaryHeld then
			return
		end

		-- Once the hold threshold is crossed, this press has become a
		-- charge intent. Releasing it must never fall back to Light Attack,
		-- even if the charge is still waiting for cooldown.
		self.PrimaryPressAttackPending = false
		self.BufferedAttack = "Charge"
		AttackInput.resolve_buffered_attack(self)
	end)
end
function AttackInput.primary_ended(self)
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
	local charge_ready = self.ChargeReady
	self.Charging = false

	if charge_ready then
		local weapon = self.WeaponController.Equipped
		local charge = weapon and weapon.Charge

		if charge then
			self.ChargeReady = false
			CombatRemote:FireServer(Protocol.Combat.HitStart, "Charge")
			AttackLifecycle.start_hitbox(self, "Charge", charge)
		end
	end

	if track then
		self.AnimationController:Resume(track)
	end

end
function AttackInput.resolve_buffered_attack(self)
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

return AttackInput
