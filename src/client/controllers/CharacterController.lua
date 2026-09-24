local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)

local Fists = require(WeaponsFolder.Fists)

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character, input_controller)
	local trove = Trove.new()

	local weapon_controller = WeaponControllerModule.new(character)
	local movement_controller = MovementControllerModule.new(character, input_controller)

	local self = setmetatable({
		Character = character,
		Trove = trove,
		WeaponController = weapon_controller,
		MovementController = movement_controller,
	}, CharacterController)

	trove:AttachToInstance(self.Character)
	trove:Add(weapon_controller)
	trove:Add(movement_controller)

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
