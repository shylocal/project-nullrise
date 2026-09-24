local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Actions = require(ReplicatedStorage.shared.input.Actions)

local MovementController = {}
MovementController.__index = MovementController

local WALK_SPEED = 16
local SPRINT_SPEED = 24

function MovementController.new(character, input_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		Trove = Trove.new(),

		Humanoid = nil,
		DefaultWalkSpeed = WALK_SPEED,
	}, MovementController)

	self:_start()

	return self
end

function MovementController:_start()
	self.Trove:AttachToInstance(self.Character)

	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self:_set_humanoid(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child)
				if child:IsA("Humanoid") then
					self:_set_humanoid(child)
				end
			end
		)
	end

	self.Trove:Connect(
		self.InputController.ActionBegan,
		function(action)
			if action == Actions.Sprint then
				self:_set_sprinting(true)
			end
		end
	)

	self.Trove:Connect(
		self.InputController.ActionEnded,
		function(action)
			if action == Actions.Sprint then
				self:_set_sprinting(false)
			end
		end
	)
end

function MovementController:_set_humanoid(humanoid)
	self.Humanoid = humanoid
	self.DefaultWalkSpeed = humanoid.WalkSpeed

	if self.InputController:IsDown(Actions.Sprint) then
		self:_set_sprinting(true)
	end
end

function MovementController:_set_sprinting(sprinting)
	local humanoid = self.Humanoid
	if not humanoid or humanoid.Parent == nil then
		return
	end

	humanoid.WalkSpeed = sprinting and SPRINT_SPEED or self.DefaultWalkSpeed
end

function MovementController:Destroy()
	self.Trove:Destroy()
end

return MovementController
