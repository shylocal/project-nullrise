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
local MANTLE_INSET = 1.25
local MANTLE_SAMPLE_STEP = 0.75
local MANTLE_SAMPLE_COUNT = 4
local JUMP_LANDING_DISTANCES = { 4, 6, 8, 10 }
local JUMP_SCAN_HEIGHT = 3
local JUMP_SCAN_DEPTH = 14
local JUMP_MAX_DROP = 8
local JUMP_MAX_RISE = 3.5
local JUMP_OFF_VERTICAL_SPEED = 42

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
		JumpOffArmed = false,
		JumpOffNormal = nil,
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
			self:_try_lower_ledge()
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		if action == Actions.Jump and self.State == "Hanging" then
			-- Releasing Space lets go. A fresh press then performs a directed
			-- jump toward nearby walkable ground, when one is visible.
			self.JumpOffArmed = true
			self.JumpOffNormal = self.Normal
			self:_release()
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
		if self.InputController:IsDown(Actions.Jump) then
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
	local normal = self.Normal
	if not root or not surface or not normal or not surface:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		-- Use the character's local right vector so A/D always match the
		-- direction the character is facing, then re-sample the surface each
		-- frame to follow curved walls instead of a fixed world-space axis.
		local tangent = flatten(root.CFrame.RightVector)
		if tangent.Magnitude < 0.05 then
			tangent = flatten(Vector3.yAxis:Cross(normal))
		end
		if tangent.Magnitude < 0.05 then
			self:_position_hanging()
			return
		end
		tangent = tangent.Unit

		local candidate_position = root.Position
			+ tangent * direction * TRAVERSE_SPEED * math.max(dt, 0)
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = self:_cast(
			probe_origin,
			-normal * (WALL_GAP + SURFACE_PROBE)
		)

		-- The side probe can hit an untagged backing wall. Treat it only as
		-- a geometric guide; the ledge's top surface is the climbability check.
		if probe then
			local top = self:_cast_top_surface(probe.Position, probe.Normal, root.Position)
			if top and self:_is_climbable(top.Instance) then
				local height_delta = root.Position.Y - top.Position.Y
				if height_delta >= -MAX_GRAB_HEIGHT and height_delta <= MAX_GRAB_HEIGHT then
					self.Surface = probe.Instance
					self.Normal = probe.Normal
					self.HangPosition = top.Position
						+ probe.Normal * WALL_GAP
						- Vector3.new(0, HANG_DROP, 0)
				end
			end
		end
	end

	-- If the probe reaches the end of a ledge or finds an invalid surface,
	-- keep the last valid hang transform rather than dropping unexpectedly.
	self:_position_hanging()
end

function ParkourController:_on_jump()
	if self.State == "Hanging" then
		return
	end

	if self.State == "Grounded" and self.JumpOffArmed then
		self.JumpOffArmed = false
		self:_jump_toward_visible_ground()
		self.JumpOffNormal = nil
		return
	end

	if self.State == "Grounded" then
		local surface, normal, position = self:_detect_surface()
		if surface then self:_grab(surface, normal, position) end
	end
end

function ParkourController:_try_lower_ledge()
	if self.State ~= "Hanging" or not self.Root or not self.HangPosition or not self.Normal then
		return
	end

	-- Probe below the current ledge, outside the wall face. A missing or
	-- non-climbable result means there is no valid lower ledge, so S is ignored.
	local current_top = self.HangPosition - self.Normal * WALL_GAP + Vector3.new(0, HANG_DROP, 0)
	local probe_origin = current_top
		+ self.Normal * (WALL_GAP + 0.2)
		- Vector3.new(0, 0.15, 0)
	local lower = self:_cast(probe_origin, Vector3.new(0, -(MAX_GRAB_HEIGHT + 0.5), 0))
	if not lower or not self:_is_climbable(lower.Instance) or lower.Normal.Y < 0.5 then
		return
	end

	local drop = current_top.Y - lower.Position.Y
	if drop < 0.5 or drop > MAX_GRAB_HEIGHT then
		return
	end

	self.Surface = lower.Instance
	self.HangPosition = lower.Position + self.Normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
	self:_position_hanging()
end

function ParkourController:_standing_height()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root then return 3 end
	return (humanoid and humanoid.HipHeight or 2) + root.Size.Y * 0.5
end

function ParkourController:_has_standing_clearance(position, normal)
	local root = self.Root
	if not root then return false end

	-- Check the character-sized volume above the candidate floor. Keep a small
	-- gap at the bottom so the supporting ledge itself is not counted as an
	-- obstruction.
	local standing_height = self:_standing_height()
	local box_size = Vector3.new(
		root.Size.X * 1.35,
		math.max(1, standing_height * 2 - 0.2),
		root.Size.Z * 1.35
	)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }

	local facing = normal and -normal or root.CFrame.LookVector
	local bounds = Workspace:GetPartBoundsInBox(
		CFrame.lookAt(position, position + facing),
		box_size,
		params
	)
	for _, part in ipairs(bounds) do
		if part.CanCollide then
			return false
		end
	end
	return true
end

function ParkourController:_complete_mantle(top, normal)
	local root = self.Root
	if not root or not top then return false end

	local standing_position = top.Position
		- normal * MANTLE_INSET
		+ Vector3.new(0, self:_standing_height() + 0.05, 0)
	if not self:_has_standing_clearance(standing_position, normal) then
		return false
	end

	self:_release()
	root.CFrame = CFrame.lookAt(standing_position, standing_position - normal)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if self.Humanoid then
		self.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	return true
end

function ParkourController:_try_mantle()
	if self.State ~= "Hanging" or not self.Root or not self.HangPosition or not self.Normal then
		return
	end

	local root = self.Root
	local normal = self.Normal
	local current_top = self.HangPosition
		- normal * WALL_GAP
		+ Vector3.new(0, HANG_DROP, 0)
	local best_top = nil
	local best_height = -math.huge
	local best_offset = math.huge

	-- Sample from the current lip inward across the platform. This finds the
	-- current ledge as well as a reachable higher tier behind it.
	for sample_index = 0, MANTLE_SAMPLE_COUNT do
		local offset = sample_index * MANTLE_SAMPLE_STEP
		local sample_position = current_top - normal * offset
		local top = self:_cast_top_surface(sample_position, normal, root.Position)
		if top and self:_is_climbable(top.Instance) and top.Normal.Y >= 0.5 then
			local height_delta = root.Position.Y - top.Position.Y
			local height_above_lip = top.Position.Y - current_top.Y
			if height_delta >= -MAX_GRAB_HEIGHT
				and height_delta <= MAX_GRAB_HEIGHT
				and height_above_lip >= -0.25 then
				local standing_position = top.Position
					- normal * MANTLE_INSET
					+ Vector3.new(0, self:_standing_height() + 0.05, 0)
				if self:_has_standing_clearance(standing_position, normal)
					and (height_above_lip > best_height
						or (height_above_lip == best_height and offset < best_offset)) then
					best_top = top
					best_height = height_above_lip
					best_offset = offset
				end
			end
		end
	end

	if best_top then
		self:_complete_mantle(best_top, normal)
	end
end

function ParkourController:_jump_toward_visible_ground()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root or not humanoid then return false end

	local normal = self.JumpOffNormal
	local outward = normal and flatten(normal) or flatten(root.CFrame.LookVector)
	if outward.Magnitude < 0.05 then
		outward = flatten(root.CFrame.LookVector)
	end
	if outward.Magnitude < 0.05 then return false end
	outward = outward.Unit

	local forward = -outward
	local right = flatten(root.CFrame.RightVector)
	local input_direction = Vector3.zero
	if self.InputController:IsDown(Actions.Forward) then input_direction += forward end
	if self.InputController:IsDown(Actions.Backward) then input_direction -= forward end
	if self.InputController:IsDown(Actions.Right) then input_direction += right end
	if self.InputController:IsDown(Actions.Left) then input_direction -= right end
	local direction = input_direction.Magnitude > 0.05 and input_direction.Unit or outward

	local landing = nil
	local landing_distance = nil
	for _, distance in ipairs(JUMP_LANDING_DISTANCES) do
		local sample = root.Position + direction * distance
		local origin = Vector3.new(sample.X, root.Position.Y + JUMP_SCAN_HEIGHT, sample.Z)
		local result = self:_cast(origin, Vector3.new(0, -JUMP_SCAN_DEPTH, 0))
		if result and result.Normal.Y >= 0.5 then
			local target_root_y = result.Position.Y + self:_standing_height()
			local rise = target_root_y - root.Position.Y
			if rise <= JUMP_MAX_RISE and rise >= -JUMP_MAX_DROP then
				-- Only use ground with an unobstructed sightline from the player.
				local sight_origin = root.Position + Vector3.new(0, 0.5, 0)
				local sight_target = result.Position + Vector3.new(0, 0.25, 0)
				local sight = self:_cast(sight_origin, sight_target - sight_origin)
				if not sight or sight.Instance == result.Instance then
					landing = result
					landing_distance = distance
					break
				end
			end
		end
	end

	if not landing then
		return false
	end

	local horizontal = flatten(landing.Position - root.Position)
	if horizontal.Magnitude < 0.05 then
		horizontal = direction
	else
		horizontal = horizontal.Unit
	end
	local gravity = math.max(Workspace.Gravity, 1)
	local rise = landing.Position.Y + self:_standing_height() - root.Position.Y
	local discriminant = JUMP_OFF_VERTICAL_SPEED ^ 2 - 2 * gravity * rise
	if discriminant < 0 then return false end
	local flight_time = (
		JUMP_OFF_VERTICAL_SPEED + math.sqrt(discriminant)
	) / gravity
	if flight_time <= 0 then return false end

	local horizontal_speed = math.clamp(landing_distance / flight_time, 10, 24)
	root.AssemblyLinearVelocity = horizontal * horizontal_speed
		+ Vector3.new(0, JUMP_OFF_VERTICAL_SPEED, 0)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	return true
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
