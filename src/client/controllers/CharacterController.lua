local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local WeaponControllerModule = require(script.Parent.WeaponController)

local Fists = require(WeaponsFolder.Fists)

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character)
	local trove = Trove.new()
	local weapon_controller = WeaponControllerModule.new(character)

	local self = setmetatable({
		Character = character,
		Trove = trove,
		WeaponController = weapon_controller,
	}, CharacterController)

	trove:AttachToInstance(self.Character)
	trove:Add(weapon_controller)

	self.WeaponController:Equip(Fists)

	return self
end

function CharacterController:IsAlive()
	return self.Character.Parent ~= nil
end

function CharacterController:Destroy()
	self.Trove:Destroy()
end

return CharacterController
