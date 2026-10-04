-- Walk/sprint speed for the local character. Sprinting requires Sprint held,
-- actual movement, and CharacterState allowing "Sprint" (hanging, vaulting or
-- rooted attacks block it). This controller is the sole writer of
-- Humanoid.WalkSpeed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local MovementConfig = require(ReplicatedStorage.shared.config).Movement

local MovementController = {}
MovementController.__index = MovementController

-- deps.character: Model; deps.input: InputController-like (ActionBegan,
-- ActionEnded, IsDown); deps.state: CharacterState.
function MovementController.new(deps)
	Deps.check(deps, "MovementController", { "character", "input", "state" })
	local self = setmetatable({
		Character = deps.character,
		Input = deps.input,
		CharacterState = deps.state,
		Trove = Trove.new(),

		Humanoid = nil,
		HumanoidTrove = nil,
		DefaultWalkSpeed = MovementConfig.WalkSpeed,
		SprintSpeed = MovementConfig.SprintSpeed,
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
		self.Input.ActionBegan,
		function(action)
			if action == Actions.Sprint then
				self:_update_sprinting()
			end
		end
	)

	self.Trove:Connect(
		self.Input.ActionEnded,
		function(action)
			if action == Actions.Sprint then
				self:_update_sprinting()
			end
		end
	)

	-- Activities starting or ending (hang, vault, rooted attack) can change
	-- whether sprinting is allowed.
	self.Trove:Connect(self.CharacterState.Changed, function()
		self:_update_sprinting()
	end)
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
	local sprinting = self.Input:IsDown(Actions.Sprint) == true
		and self:_is_moving()
		and self.CharacterState:CanStart("Sprint")
	local changed = self.Sprinting ~= sprinting

	self.Sprinting = sprinting

	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent ~= nil then
		local target = sprinting and self.SprintSpeed or self.DefaultWalkSpeed
		if humanoid.WalkSpeed ~= target then
			humanoid.WalkSpeed = target
		end
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

function MovementController:IsSprinting()
	return self.Sprinting
end

function MovementController:Destroy()
	self.Trove:Destroy()
end

return MovementController
