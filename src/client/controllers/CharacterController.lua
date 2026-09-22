--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

local Weapons = require(ReplicatedStorage.Shared.weapons)
local WeaponControllerModule = require(script.Parent.WeaponController)

local Fists = Weapons.Fists

export type CharacterController = {
	Character: Model,
	Trove: typeof(Trove.new()),
	WeaponController: WeaponControllerModule.WeaponController,
	Destroy: (self: CharacterController) -> (),
	IsAlive: (self: CharacterController) -> boolean,
}

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character: Model): CharacterController
	local self = setmetatable({
		Character = character,
		Trove = Trove.new(),
		WeaponController = WeaponControllerModule.new(character),
	}, CharacterController)

	self.Trove:AttachToInstance(self.Character)

	return self
end

function CharacterController:IsAlive(): boolean
	return self.Character.Parent ~= nil
end

function CharacterController:Destroy()
	self.WeaponController:Destroy()
	self.Trove:Destroy()
end

return CharacterController
