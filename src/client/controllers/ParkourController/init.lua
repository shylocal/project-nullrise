local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local ParkourController = {}
ParkourController.__index = ParkourController

local CLIMBABLE_TAG = "Climbable"
local WALL_REACH = 3.25
local TOP_SCAN_HEIGHT = 3.5
local MAX_GRAB_HEIGHT = 4.5
local HANG_DROP = 2.35
local WALL_GAP = 0.8
local TRAVERSE_SPEED = 5
local SURFACE_PROBE = 1.4

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

function ParkourController.new(character, input_controller, movement_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		MovementController = movement_controller,
		Trove = Trove.new(),
		State = "Grounded",
		Humanoid = character:FindFirstChildOfClass("Humanoid"),
		Root = character:FindFirstChild("HumanoidRootPart"),
		Surface = nil,
		Normal = nil,
		HangPosition = nil,
		AutoRotateBeforeHang = nil,
		PlatformStandBeforeHang = nil,
		JumpReleased = true,
	}, ParkourController)

	self:_start()
	return self
end

function ParkourController:_start()
	self.Trove:Connect(self.InputController.ActionBegan, function(action)
		if action == Actions.Jump then
			self:_on_jump()
		elseif action == Actions.Forward and self.State == "Hanging" then
			self:_try_mantle()
		elseif action == Actions.Backward and self.State == "Hanging" then
			self:_release()
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		if action == Actions.Jump then
			self.JumpReleased = true
		end
	end)

	self.Trove:Connect(RunService.Heartbeat, function(dt)
		self:_step(dt)
	end)

	self:_bind_character_parts()
	self.Trove:Connect(self.Character.ChildAdded, function(child)
		if child.Name == "HumanoidRootPart" then
			self.Root = child
		elseif child:IsA("Humanoid") then
			self:_bind_humanoid(child)
		end
	end)
end

function ParkourController:_bind_character_parts()
	self.Root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then self:_bind_humanoid(humanoid) end
end

function ParkourController:_bind_humanoid(humanoid)
	if self.Humanoid == humanoid then return end
	self.Humanoid = humanoid
	self.Trove:Connect(humanoid.Died, function()
		self:_release()
	end)
end

function ParkourController:_cast(origin, direction)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	return Workspace:Raycast(origin, direction, params)
end

function ParkourController:_is_climbable(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, CLIMBABLE_TAG) then
			return true
		end
		current = current.Parent
	end
	return false
end

function ParkourController:_cast_top_surface(wall_position, wall_normal, root_position)
	-- Start above the maximum reachable ledge, then sample just inside the wall
	-- footprint. Starting outside the footprint can miss narrow tops; starting
	-- below the top can leave the ray origin inside the wall and miss it.
	local top_origin = Vector3.new(
		wall_position.X,
		root_position.Y + MAX_GRAB_HEIGHT + 0.25,
		wall_position.Z
	) - wall_normal * 0.1
	local scan_depth = MAX_GRAB_HEIGHT * 2 + 1
	return self:_cast(top_origin, Vector3.new(0, -scan_depth, 0))
end

function ParkourController:_detect_surface()
	local root = self.Root
	if not root then return nil end

	local direction = flatten(root.CFrame.LookVector)
	if direction.Magnitude < 0.1 then return nil end
	direction = direction.Unit

	local origin = root.Position + Vector3.new(0, 1.1, 0)
	local wall = self:_cast(origin, direction * WALL_REACH)
	if not wall or not self:_is_climbable(wall.Instance) then return nil end

	local top = self:_cast_top_surface(wall.Position, wall.Normal, root.Position)
	if not top then return nil end
	if not self:_is_climbable(top.Instance) then return nil end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -MAX_GRAB_HEIGHT or height_delta > MAX_GRAB_HEIGHT then return nil end

	local hang_position = top.Position + wall.Normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
	local body_clearance = self:_cast(
		hang_position + Vector3.new(0, 0.8, 0),
		-wall.Normal * 0.35
	)
	if body_clearance and not self:_is_climbable(body_clearance.Instance) then return nil end

	return wall.Instance, wall.Normal, hang_position
end

function ParkourController:_grab(surface, normal, position)
	if self.State ~= "Grounded" then return end
	self.State = "Hanging"
	self.Surface = surface
	self.Normal = normal
	self.HangPosition = position

	local humanoid = self.Humanoid
	if humanoid then
		self.AutoRotateBeforeHang = humanoid.AutoRotate
		self.PlatformStandBeforeHang = humanoid.PlatformStand
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end

	self.MovementController:SetSprintBlocked(true)
	self:_position_hanging()
end

function ParkourController:_position_hanging()
	local root = self.Root
	local position = self.HangPosition
	local normal = self.Normal
	if not root or not position or not normal then return end

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(position, position - normal)
end

function ParkourController:_step(dt)
	if self.State == "Grounded" then
		if self.InputController:IsDown(Actions.Jump)
			and self.InputController:IsDown(Actions.Sprint) then
			local surface, normal, position = self:_detect_surface()
			if surface then self:_grab(surface, normal, position) end
		end
	elseif self.State == "Hanging" then
		self:_traverse(dt)
	end
end

function ParkourController:_traverse(dt)
	local root = self.Root
	local surface = self.Surface
	if not root or not surface or not surface:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	local tangent = self.Normal:Cross(Vector3.yAxis)
	if tangent.Magnitude < 0.05 then
		tangent = flatten(root.CFrame.RightVector)
	end
	if tangent.Magnitude < 0.05 then return end
	tangent = tangent.Unit

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		local delta = tangent * direction * TRAVERSE_SPEED * dt
		local probe_origin = root.Position + delta + Vector3.new(0, 1.1, 0) + self.Normal * 0.3
		local probe = self:_cast(probe_origin, -self.Normal * (WALL_GAP + SURFACE_PROBE))
		if probe and self:_is_climbable(probe.Instance) then
			local top = self:_cast_top_surface(probe.Position, probe.Normal, root.Position)
			if top and self:_is_climbable(top.Instance) then
				self.Surface = probe.Instance
				self.Normal = probe.Normal
				self.HangPosition = top.Position + probe.Normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
			end
		end
	end

	self:_position_hanging()
end

function ParkourController:_on_jump()
	if self.State == "Hanging" then
		if self.JumpReleased then
			self:_release()
			self.JumpReleased = false
			if self.Humanoid then
				self.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end
		end
		return
	end

	if self.State == "Grounded" and self.InputController:IsDown(Actions.Sprint) then
		local surface, normal, position = self:_detect_surface()
		if surface then self:_grab(surface, normal, position) end
	end
end

function ParkourController:_try_mantle()
	-- Reserved for the next traversal milestone after surface-following is validated.
end

function ParkourController:_release()
	if self.State ~= "Hanging" then return end
	self.State = "Grounded"
	self.Surface = nil
	self.Normal = nil
	self.HangPosition = nil

	local humanoid = self.Humanoid
	if humanoid then
		humanoid.AutoRotate = self.AutoRotateBeforeHang
		humanoid.PlatformStand = self.PlatformStandBeforeHang
	end
	self.AutoRotateBeforeHang = nil
	self.PlatformStandBeforeHang = nil
	if self.MovementController then
		self.MovementController:SetSprintBlocked(false)
	end
end

function ParkourController:Destroy()
	self:_release()
	self.Trove:Destroy()
end

return ParkourController
