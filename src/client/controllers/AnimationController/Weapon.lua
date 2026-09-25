local Weapon = {}
Weapon.__index = Weapon

function Weapon.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		EquipTrack = nil,
	}, Weapon)

	animation_controller.AnimatorChanged:Connect(function()
		self:_load()

		if self.Weapon then
			self:PlayEquip()
		end
	end)

	return self
end

function Weapon:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load()
	self:PlayEquip()
end

function Weapon:_load()
	self.EquipTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return nil
	end

	self.EquipTrack = self.Controller:Load(
		weapon.Animations and weapon.Animations.Equip
	)

	return self.EquipTrack
end

function Weapon:PlayEquip()
	local track = self.EquipTrack or self:_load()
	if not track then
		return nil
	end

	local definition = self.Weapon
		and self.Weapon.Animations
		and self.Weapon.Animations.Equip

	return self.Controller:PlayAction(
		track,
		definition and definition.TransitionTime or 0
	)
end

function Weapon:Clear()
	self.EquipTrack = nil
end

return Weapon
