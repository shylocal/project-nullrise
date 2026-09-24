local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponsFolder = ReplicatedStorage.shared.weapons

local WeaponController = {}
WeaponController.__index = WeaponController

function WeaponController.new(character)
	return setmetatable({
		Character = character,
		Equipped = nil,
	}, WeaponController)
end

function WeaponController:GetWielded(wield_name)
	return self.Character:FindFirstChild(wield_name)
end

function WeaponController:EquipById(weapon_id)
	local weapon_module = WeaponsFolder:FindFirstChild(weapon_id)
	if not weapon_module or not weapon_module:IsA("ModuleScript") then
		return false
	end

	local weapon = require(weapon_module)

	if weapon.Type ~= "Melee" then
		return false
	end

	return self:Equip(weapon)
end

function WeaponController:Equip(weapon)
	if not weapon or weapon.Type ~= "Melee" then
		return false
	end

	self.Equipped = weapon
	return true
end

function WeaponController:Destroy()
end

return WeaponController
