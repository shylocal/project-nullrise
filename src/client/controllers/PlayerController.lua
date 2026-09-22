--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))
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
	-- Handle an already-spawned character before subscribing. This avoids
	-- missing the current character when the controller starts late.
	if self.Player.Character then
		self:_set_character(self.Player.Character)
	end

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

	-- PlayerRemoving is the final ownership boundary. Destroying the Trove
	-- disconnects all player lifecycle listeners and the active character.
	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player)
			if player == self.Player then
				self:Destroy()
			end
		end
	)
end

function PlayerController:_set_character(character: Model)
	local previous = self.CharacterController

	if previous and previous.Character == character then
		return
	end

	self:_clear_character()

	-- The player can be removed between CharacterAdded firing and this code
	-- running. Avoid creating a controller for an already-detached character.
	if self.Player.Parent ~= Players or not character:IsDescendantOf(Workspace) then
		return
	end

	self.CharacterController = CharacterControllerModule.new(character)

	-- CharacterController owns its own resources. Adding it to this Trove
	-- makes the ownership explicit and guarantees cleanup with the player.
	self.Trove:Add(self.CharacterController)
end

function PlayerController:_clear_character()
	local character_controller = self.CharacterController
	self.CharacterController = nil

	if character_controller then
		character_controller:Destroy()
	end
end

function PlayerController:Destroy()
	local trove = self.Trove

	if not trove then
		return
	end

	self.Trove = nil :: any
	self.CharacterController = nil
	trove:Destroy()
end

return PlayerController
