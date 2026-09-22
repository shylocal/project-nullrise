--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Trove"))

export type CharacterController = {
	Character: Model,
	Trove: typeof(Trove.new()),
	Destroy: (self: CharacterController) -> (),
	IsAlive: (self: CharacterController) -> boolean,
}

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character: Model): CharacterController
	local self = setmetatable({
		Character = character,
		Trove = Trove.new(),
	}, CharacterController)

	self:_start()

	return self
end

function CharacterController:_start()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		self:_on_humanoid_added(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child)
				if not child:IsA("Humanoid") then
					return
				end

				self:_on_humanoid_added(child)
			end
		)
	end

	-- A character can disappear without CharacterRemoving being useful to
	-- the controller owner, especially during unusual teardown/reparenting.
	self.Trove:Connect(
		self.Character.Destroying,
		function()
			self:Destroy()
		end
	)
end

function CharacterController:_on_humanoid_added(humanoid: Humanoid)
	-- CharacterController is intentionally lifecycle-focused for now.
	-- Gameplay/animation/input behaviour can subscribe here without owning
	-- the character's lifetime.
	self.Trove:Add(
		humanoid.Died:Connect(function()
			-- Keep the controller alive until the character is actually removed.
			-- Roblox can leave the model around after death for a respawn period.
		end)
	)
end

function CharacterController:IsAlive(): boolean
	return self.Character.Parent ~= nil
end

function CharacterController:Destroy()
	if not self.Trove then
		return
	end

	self.Trove:Destroy()
	self.Trove = nil :: any
end

return CharacterController
