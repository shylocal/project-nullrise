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
	-- If Roblox destroys the character directly, make the character's Trove
	-- responsible for all owned connections/resources as well.
	self.Trove:AttachToInstance(self.Character)

	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		self:_on_humanoid_added(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child)
				if child:IsA("Humanoid") then
					self:_on_humanoid_added(child)
				end
			end
		)
	end
end

function CharacterController:_on_humanoid_added(_humanoid: Humanoid)
	-- Character-specific gameplay can be added here later.
	-- The controller owns the character lifecycle, not the gameplay state.
end

function CharacterController:IsAlive(): boolean
	return self.Character.Parent ~= nil
end

function CharacterController:Destroy()
	self.Trove:Destroy()
end

return CharacterController
