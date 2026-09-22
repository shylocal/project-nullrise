--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local CharacterControllerModule = require(script.Parent.CharacterController)

export type PlayerController = {
	Player: Player,
	Trove: typeof(Trove.new()),
	CharacterController: CharacterControllerModule.CharacterController?,
	Destroy: (self: PlayerController) -> (),
}

local PlayerController = {}
PlayerController.__index = PlayerController

function PlayerController.new(player: Player): PlayerController
	local self = setmetatable({
		Player = player,
		Trove = Trove.new(),
		CharacterController = nil,
	}, PlayerController)

	self:_start()

	return self
end

function PlayerController:_start()
	-- Subscribe before checking the current character:
	-- this handles both an already-spawned character and a spawn that happens
	-- immediately after bootstrap without requiring a yield.
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

	-- CharacterAdded may have happened before the controller was created.
	local current_character = self.Player.Character
	if current_character then
		self:_set_character(current_character)
	end
end

function PlayerController:_set_character(character: Model)
	local current = self.CharacterController

	if current and current.Character == character then
		return
	end

	self:_clear_character()

	-- CharacterAdded is expected to provide a character parented into the
	-- data model. If the player is already being removed, don't keep an object
	-- alive for a character that is no longer part of the game.
	if self.Player.Parent ~= Players or not character:IsDescendantOf(Workspace) then
		return
	end

	local controller = CharacterControllerModule.new(character)
	self.CharacterController = controller
	self.Trove:Add(controller)
end

function PlayerController:_clear_character()
	local controller = self.CharacterController
	self.CharacterController = nil

	if controller then
		controller:Destroy()
	end
end

function PlayerController:Destroy()
	self.Trove:Destroy()
	self.CharacterController = nil
end

return PlayerController
