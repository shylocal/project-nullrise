local Combat = {}
Combat.__index = Combat

function Combat.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,

		AttackTracks = {},
		ChargeTrack = nil,
	}, Combat)

	animation_controller.AnimatorChanged:Connect(function()
		self:_load()
	end)

	return self
end

function Combat:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load()
end

function Combat:_load()
	table.clear(self.AttackTracks)
	self.ChargeTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return
	end

	for attack_index, attack in pairs(weapon.Attacks or {}) do
		if attack.Animation then
			self.AttackTracks[attack_index] = self.Controller:Load(attack.Animation)
		end
	end

	if weapon.Charge and weapon.Charge.Animation then
		self.ChargeTrack = self.Controller:Load(weapon.Charge.Animation)
	end
end

function Combat:BeginAttack(attack_index)
	local track = self.AttackTracks[attack_index]
	if not track then
		return nil
	end

	self.Controller:ClaimAction(track)

	return track
end

function Combat:BeginCharge()
	local track = self.ChargeTrack
	if not track then
		return nil
	end

	self.Controller:ClaimAction(track)

	return track
end

function Combat:Play(track, transition_time)
	self.Controller:Play(track, transition_time)
end

function Combat:Pause(track)
	self.Controller:Pause(track)
end

function Combat:Resume(track)
	self.Controller:Resume(track)
end

function Combat:StopAction()
	self.Controller:StopAction()
end

function Combat:Clear()
	table.clear(self.AttackTracks)
	self.ChargeTrack = nil
end

function Combat:Destroy()
	self:Clear()
end

return Combat
