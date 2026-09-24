local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local CharacterControllerModule = require(script.Parent.CharacterController)

local PlayerController = {}
PlayerController.__index = PlayerController

function PlayerController.new(player, input_controller, weapon_menu_controller)
	local self = setmetatable({
		Player = player,
		Trove = Trove.new(),
		CharacterController = nil,
		InputController = input_controller,
		WeaponMenuController = weapon_menu_controller,
	}, PlayerController)

	self:_start()

	return self
end

function PlayerController:_start()
	self.Trove:Connect(
		self.Player.CharacterAdded,
		function(character)
			self:_set_character(character)
		end
	)

	self.Trove:Connect(
		self.Player.CharacterRemoving,
		function(character)
			if self.CharacterController and self.CharacterController.Character == character then
				self:_clear_character()
			end
		end
	)

	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player)
			if player == self.Player then
				self:Destroy()
			end
		end
	)

	local current_character = self.Player.Character
	if current_character then
		self:_set_character(current_character)
	end
end

function PlayerController:_set_character(character)
	local current = self.CharacterController

	if current and current.Character == character then
		return
	end

	self:_clear_character()

	if self.Player.Parent ~= Players or not character:IsDescendantOf(Workspace) then
		return
	end

	local controller = CharacterControllerModule.new(
		character,
		self.InputController,
		self.WeaponMenuController
	)

	self.CharacterController = controller
	self.Trove:Add(controller)
end

function PlayerController:_clear_character()
	local controller = self.CharacterController
	self.CharacterController = nil

	if controller then
		self.Trove:Remove(controller)
	end
end

function PlayerController:Destroy()
	self.Trove:Destroy()
	self.CharacterController = nil
end

return PlayerController
