local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local MovementConfig = require(ReplicatedStorage.shared.movement.Config)

local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(character, input_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		Trove = Trove.new(),

		Humanoid = nil,
		HumanoidTrove = nil,
		DefaultWalkSpeed = MovementConfig.WalkSpeed,
		SprintSpeed = MovementConfig.SprintSpeed,
		SprintBlocked = false,
		SprintBlockers = {},
		Sprinting = false,

		SprintingChanged = Signal.new(),
	}, MovementController)

	self.Trove:Add(self.SprintingChanged)
	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function MovementController:_start()
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
				self:_update_sprinting()
			end
		end
	)

	self.Trove:Connect(
		self.InputController.ActionEnded,
		function(action)
			if action == Actions.Sprint then
				self:_update_sprinting()
			end
		end
	)
end

function MovementController:_set_humanoid(humanoid)
	self.Humanoid = humanoid

	-- MovementConfig (or a SetSpeeds override) is authoritative for speed;
	-- _update_sprinting writes it to the Humanoid instead of adopting the
	-- Humanoid's existing WalkSpeed.
	if self.HumanoidTrove then
		self.HumanoidTrove:Clean()
	else
		self.HumanoidTrove = self.Trove:Extend()
	end
	self.HumanoidTrove:Connect(
		humanoid:GetPropertyChangedSignal("MoveDirection"),
		function()
			self:_update_sprinting()
		end
	)

	self:_update_sprinting()
end

function MovementController:_is_moving()
	local humanoid = self.Humanoid
	return humanoid ~= nil
		and humanoid.MoveDirection.Magnitude >= MovementConfig.SprintMinMoveMagnitude
end

function MovementController:_update_sprinting()
	-- Holding Sprint while standing still must not enter the sprint state.
	local sprinting = not self.SprintBlocked
		and self.InputController:IsDown(Actions.Sprint)
		and self:_is_moving()
	local changed = self.Sprinting ~= sprinting

	self.Sprinting = sprinting

	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent ~= nil then
		humanoid.WalkSpeed = sprinting and self.SprintSpeed or self.DefaultWalkSpeed
	end

	if changed then
		self.SprintingChanged:Fire(sprinting)
	end
end

function MovementController:SetSpeeds(walk_speed, sprint_speed)
	local function is_valid_speed(value)
		return typeof(value) == "number" and math.isfinite(value) and value >= 0
	end

	if not is_valid_speed(walk_speed) or not is_valid_speed(sprint_speed) then
		return false
	end

	self.DefaultWalkSpeed = walk_speed
	self.SprintSpeed = sprint_speed
	self:_update_sprinting()
	return true
end

function MovementController:SetSprintBlocked(blocked, reason)
	reason = reason or self
	if blocked then
		self.SprintBlockers[reason] = true
	else
		self.SprintBlockers[reason] = nil
	end

	local sprint_blocked = next(self.SprintBlockers) ~= nil
	if self.SprintBlocked == sprint_blocked then
		return
	end

	self.SprintBlocked = sprint_blocked
	self:_update_sprinting()
end

function MovementController:IsSprinting()
	return self.Sprinting
end

function MovementController:Destroy()
	table.clear(self.SprintBlockers)
	self.SprintBlocked = false
	self.Trove:Destroy()
end

return MovementController
