--!strict
-- Walk/sprint speed for the local character. Sprinting requires Sprint held,
-- actual movement, and CharacterState allowing "Sprint" (hanging, vaulting or
-- rooted attacks block it). This controller is the sole writer of
-- Humanoid.WalkSpeed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Signal = require(Packages.Signal)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local MovementConfig = require(ReplicatedStorage.shared.config).Movement

local ClientTrove = require(script.Parent.Parent.ClientTrove)
local CharacterStateModule = require(script.Parent.CharacterState)

type Signal = typeof(Signal.new())
type Trove = ClientTrove.Trove

-- The input dependency (InputController or a spec fake). Method `self` is
-- `any` so both metatable classes and plain fakes satisfy the shape.
export type InputLike = {
	ActionBegan: Signal,
	ActionEnded: Signal,
	IsDown: (self: any, action: string) -> boolean,
}

export type Deps = {
	character: Model,
	input: InputLike,
	state: CharacterStateModule.CharacterState,
}

local MovementController = {}
MovementController.__index = MovementController

export type MovementController = typeof(setmetatable(
	{} :: {
		Character: Model,
		Input: InputLike,
		CharacterState: CharacterStateModule.CharacterState,
		Trove: Trove,
		Humanoid: Humanoid?,
		HumanoidTrove: Trove?,
		DefaultWalkSpeed: number,
		SprintSpeed: number,
		Sprinting: boolean,
		-- Fires (sprinting: boolean) when the sprint state changes.
		SprintingChanged: Signal,
	},
	MovementController
))

-- deps.input: InputController-like (ActionBegan, ActionEnded, IsDown);
-- deps.state: CharacterState.
function MovementController.new(deps: Deps): MovementController
	Deps.check(deps, "MovementController", { "character", "input", "state" })
	local self: MovementController = setmetatable({
		Character = deps.character,
		Input = deps.input,
		CharacterState = deps.state,
		Trove = ClientTrove.new(),

		Humanoid = nil,
		HumanoidTrove = nil,
		DefaultWalkSpeed = MovementConfig.WalkSpeed,
		SprintSpeed = MovementConfig.SprintSpeed,
		Sprinting = false,

		SprintingChanged = Signal.new(),
	}, MovementController)

	self.Trove:Add(self.SprintingChanged)
	local ok, err = pcall(self._start :: (MovementController) -> any, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function MovementController._start(self: MovementController)
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self:_set_humanoid(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child: Instance)
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

function MovementController._set_humanoid(self: MovementController, humanoid: Humanoid)
	self.Humanoid = humanoid

	-- MovementConfig (or a SetSpeeds override) is authoritative for speed;
	-- _update_sprinting writes it to the Humanoid instead of adopting the
	-- Humanoid's existing WalkSpeed.
	local humanoid_trove: Trove
	local existing = self.HumanoidTrove
	if existing then
		existing:Clean()
		humanoid_trove = existing
	else
		humanoid_trove = self.Trove:Extend()
		self.HumanoidTrove = humanoid_trove
	end
	humanoid_trove:Connect(
		humanoid:GetPropertyChangedSignal("MoveDirection"),
		function()
			self:_update_sprinting()
		end
	)

	self:_update_sprinting()
end

function MovementController._is_moving(self: MovementController): boolean
	local humanoid = self.Humanoid
	return humanoid ~= nil
		and humanoid.MoveDirection.Magnitude >= MovementConfig.SprintMinMoveMagnitude
end

function MovementController._update_sprinting(self: MovementController)
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

function MovementController.SetSpeeds(self: MovementController, walk_speed: number, sprint_speed: number): boolean
	local function is_valid_speed(value: any): boolean
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

function MovementController.IsSprinting(self: MovementController): boolean
	return self.Sprinting
end

function MovementController.Destroy(self: MovementController)
	self.Trove:Destroy()
end

return MovementController
