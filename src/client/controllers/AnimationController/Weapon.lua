local Weapon = {}
Weapon.__index = Weapon

function Weapon.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		EquipTrack = nil,
		EquipPending = false,
	}, Weapon)

	animation_controller.AnimatorChanged:Connect(function()
		self:_load()

		if self.EquipPending then
			self:PlayEquip()
		end
	end)

	return self
end

function Weapon:SetWeapon(weapon)
	self.Weapon = weapon
	self.EquipPending = false
	self:_load()
end

function Weapon:_load()
	self.EquipTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return
	end

	self.EquipTrack = self.Controller:Load(
		weapon.Animations and weapon.Animations.Equip
	)
end

function Weapon:PlayEquip()
	self.EquipPending = true

	local track = self.EquipTrack

	if not track then
		if not self.Controller.Animator or self.Controller.Animator.Parent == nil then
			return nil
		end

		self.EquipPending = false
		self.Controller.Movement:Update()
		return nil
	end

	self.EquipPending = false

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

function Weapon:Destroy()
	self:Clear()
end

return Weapon
