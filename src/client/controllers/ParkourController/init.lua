local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local ParkourController = {}
ParkourController.__index = ParkourController

local Config = require(script.Config)

local function vault_debug(...)
	if Config.VaultDebug then
		print("[ParkourVault]", ...)
	end
end

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Shape the vertical arc so its apex lines up with the obstacle,
-- rather than always landing halfway through the entire scripted trajectory.
-- This matters when detection starts the vault well before the wall.
local function vault_arc_weight(linear, peak_progress)
	local peak = math.clamp(peak_progress or 0.5, 0.2, 0.92)
	if linear <= peak then
		return math.sin((linear / peak) * math.pi * 0.5)
	end
	return math.cos(((linear - peak) / (1 - peak)) * math.pi * 0.5)
end

local function vault_hip_height_weight(linear)
	-- Reach the lowered pose quickly, hold it through most of the vault,
	-- then blend back to the original HipHeight during the final phase.
	local function smoothstep(value)
		value = math.clamp(value, 0, 1)
		return value * value * (3 - 2 * value)
	end

	local fade_in = smoothstep(linear / 0.18)
	local fade_out = smoothstep((1 - linear) / 0.22)
	return fade_in * fade_out
end

function ParkourController.new(character, input_controller, movement_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		MovementController = movement_controller,
		Trove = Trove.new(),
		State = "Grounded",
		Humanoid = nil,
		BoundHumanoid = nil,
		Root = character:FindFirstChild("HumanoidRootPart"),
		CurrentClimbable = nil,
		Normal = nil,
		HangDepthOffset = nil,
		HangPosition = nil,
		AutoRotateBeforeHang = nil,
		PlatformStandBeforeHang = nil,
		GrabBlockedUntilJumpReleased = false,
		VaultJumpingEnabledBefore = nil,
		VaultAutoRotateBefore = nil,
		VaultPlatformStandBefore = nil,
		VaultHipHeightBefore = nil,
		VaultHipHeightHumanoid = nil,
		_vaultExitVelocity = nil,
		NextVaultAt = 0,
		CornerLockPosition = nil,
		CornerLockInputDirection = nil,
	}, ParkourController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function ParkourController:_start()
	self.Trove:Connect(self.InputController.ActionBegan, function(action)
		if action == Actions.Jump then
			vault_debug("Space action received; state=", self.State,
				"sprinting=", self.MovementController and self.MovementController:IsSprinting() or false,
				"jumpBlocked=", self.GrabBlockedUntilJumpReleased)
			if self.State == "Grounded" then
				-- Space explicitly requests a vault; if no valid vault is found,
				-- the ordinary jump or ledge-grab flow remains available.
				self:_try_vault()
			else
				vault_debug("Space action ignored: state is not Grounded", self.State)
			end
		elseif action == Actions.Forward and self.State == "Hanging" then
			self:_try_mantle()
		elseif action == Actions.Backward and self.State == "Hanging" then
			self:_try_lower_ledge()
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		if action == Actions.Jump then
			if self.GrabBlockedUntilJumpReleased then
				self.GrabBlockedUntilJumpReleased = false
				if self.Humanoid and self.State ~= "Vaulting" then
					local jumping_enabled = self.JumpingEnabledBeforeMantle
					if jumping_enabled == nil then
						jumping_enabled = self.VaultJumpingEnabledBefore
					end
					if jumping_enabled ~= nil then
						self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, jumping_enabled)
						self.JumpingEnabledBeforeMantle = nil
						self.VaultJumpingEnabledBefore = nil
					end
				end
				if self.State == "Grounded" and self.Humanoid then
					if self.AutoRotateBeforeHang ~= nil then self.Humanoid.AutoRotate = self.AutoRotateBeforeHang end
					if self.PlatformStandBeforeHang ~= nil then self.Humanoid.PlatformStand = self.PlatformStandBeforeHang end
					self.AutoRotateBeforeHang = nil
					self.PlatformStandBeforeHang = nil
				end
			end
			if self.State == "Hanging" then
				-- Releasing Space simply lets go; normal gravity handles the drop.
				self:_release()
			end
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
	if humanoid then
		self:_bind_humanoid(humanoid)
	end
end

function ParkourController:_bind_humanoid(humanoid)
	if self.BoundHumanoid == humanoid then return end
	self.BoundHumanoid = humanoid
	self.Humanoid = humanoid
	self.Trove:Connect(humanoid.Died, function()
		self:_release()
	end)
end

function ParkourController:_cast(origin, direction, respect_can_collide)
	local params = self._castParams or RaycastParams.new()
	self._castParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = respect_can_collide == true
	return Workspace:Raycast(origin, direction, params)
end

function ParkourController:_cast_climbable_side(origin, direction)
	local params = self._sideCastParams or RaycastParams.new()
	self._sideCastParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local exclusions = { self.Character }
	for _ = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local hit = Workspace:Raycast(origin, direction, params)
		if not hit then
			return nil
		end
		if self:_is_climbable(hit.Instance) then
			return hit
		end

		-- Skip decorative non-collidable geometry, but never ray through a
		-- solid non-climbable wall or platform.
		if not hit.Instance:IsA("BasePart") or hit.Instance.CanCollide then
			return nil
		end
		table.insert(exclusions, hit.Instance)
	end
	return nil
end

function ParkourController:_get_climbable_guide(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, Config.ClimbableTag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ParkourController:_is_climbable(instance)
	return self:_get_climbable_guide(instance) ~= nil
end

function ParkourController:_cast_reachable_grab_top(wall_position, wall_normal, root_position, reference_y)
	-- Several climb guides can overlap vertically. A single downward ray hits
	-- the highest one first, even when that ledge is outside grab range. Walk
	-- down through successive hits and choose the climbable, walkable top closest
	-- in height to the character.
	local standing_height = self:_standing_height()
	local origin = Vector3.new(
		wall_position.X,
		root_position.Y + Config.MaxGrabHeight + standing_height + 2,
		wall_position.Z
	) - wall_normal * 0.1
	local direction = Vector3.new(
		0,
		-(Config.MaxGrabHeight * 2 + standing_height + 4),
		0
	)

	local params = self._reachableTopParams or RaycastParams.new()
	self._reachableTopParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local exclusions = { self.Character }
	local best = nil
	local best_height_distance = math.huge
	for hit_index = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local candidate = Workspace:Raycast(origin, direction, params)
		if not candidate then
			break
		end

		local height_delta = (reference_y or root_position.Y) - candidate.Position.Y
		local height_distance = math.abs(height_delta)
		local climbable = self:_is_climbable(candidate.Instance)
		local walkable = candidate.Normal.Y >= 0.5
		local reachable = height_delta >= -Config.MaxGrabHeight
			and height_delta <= Config.MaxGrabHeight

		if climbable and walkable and reachable and height_distance < best_height_distance then
			best = candidate
			best_height_distance = height_distance
		end

		table.insert(exclusions, candidate.Instance)
	end

	return best
end

function ParkourController:_detect_surface()
	local root = self.Root
	if not root then
				return nil
	end

	local direction = flatten(root.CFrame.LookVector)
	if direction.Magnitude < 0.1 then
				return nil
	end
	direction = direction.Unit

	local origin = root.Position + Vector3.new(0, 1.1, 0)
	local wall = self:_cast(origin, direction * Config.WallReach)
	if not wall then
				return nil
	end
	if not self:_is_climbable(wall.Instance) then
				return nil
	end

	local top = self:_cast_reachable_grab_top(wall.Position, wall.Normal, root.Position, root.Position.Y)
	if not top then
				return nil
	end
	if not self:_is_climbable(top.Instance) then
				return nil
	end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -Config.MaxGrabHeight or height_delta > Config.MaxGrabHeight then
				return nil
	end

	local hang_normal = flatten(wall.Normal)
	if hang_normal.Magnitude < 0.05 then
				return nil
	end
	hang_normal = hang_normal.Unit
	local hang_position = top.Position + hang_normal * Config.WallGap - Vector3.new(0, Config.HangDrop, 0)
	local body_clear, blocking_part = self:_has_hang_body_clearance(
		hang_position,
		hang_normal,
		{
			wall.Instance,
			top.Instance,
			self:_get_climbable_guide(wall.Instance),
			self:_get_climbable_guide(top.Instance),
		}
	)
	if not body_clear then
				return nil
	end

		return self:_get_climbable_guide(top.Instance), hang_normal, hang_position
end

function ParkourController:_grab(guide, normal, position)
	if self.State ~= "Grounded" or not guide then return end
		self.State = "Hanging"
	self.CurrentClimbable = guide
	self.Normal = normal
	self.HangDepthOffset = flatten(normal).Unit * Config.WallGap
	self.HangPosition = position

	local humanoid = self.Humanoid
	if humanoid then
		self.AutoRotateBeforeHang = humanoid.AutoRotate
		self.PlatformStandBeforeHang = humanoid.PlatformStand
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end

	if self.MovementController and self.MovementController.SetSprintBlocked then
		self.MovementController:SetSprintBlocked(true, self)
	end
	self:_position_hanging()
end

function ParkourController:_position_hanging()
	local root = self.Root
	local position = self.HangPosition
	local normal = self.Normal
	if not root or not position or not normal then return end

	local target = CFrame.lookAt(position, position - normal)
	local dt = self._stepDelta or 1 / 60
	local alpha = 1 - math.exp(-Config.ClimbSmoothness * math.max(dt, 0))
	local current = root.CFrame

	-- Keep lateral traversal responsive: smoothing X/Z makes A/D lag behind
	-- the validated hang point and can pull the body into a ledge during a
	-- simultaneous vertical transfer. Smooth only the vertical component.
	local smoothed_y = current.Position.Y + (position.Y - current.Position.Y) * alpha
	local smoothed_rotation = current.Rotation:Lerp(target.Rotation, alpha)
	root.CFrame = CFrame.new(position.X, smoothed_y, position.Z) * smoothed_rotation
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

function ParkourController:_has_hang_body_clearance(position, normal)
	local root = self.Root
	local character = self.Character
	if not root or not character or not position or not normal then
		return false
	end

	local facing = flatten(normal)
	if facing.Magnitude < 0.05 then
		return false
	end
	facing = facing.Unit

	-- Use the HumanoidRootPart collision envelope rather than the whole avatar
	-- bounding box. Accessories and non-colliding limbs can extend well beyond
	-- the actual movement collider and falsely reject tight but valid corners.
	local target_cframe = CFrame.lookAt(position, position - facing)
	-- Query with a box-shaped probe against exact part geometry. The bounds
	-- query below can treat a cylinder's enclosing box as solid, falsely
	-- rejecting otherwise clear positions beside its curved surface.
	local probe = self.HangClearanceProbe
	if not probe or not probe.Parent then
		probe = Instance.new("Part")
		probe.Name = "ParkourHangClearanceProbe"
		probe.Anchored = true
		probe.CanCollide = false
		probe.CanTouch = false
		probe.CanQuery = true
		probe.CollisionGroup = "Climbable"
		probe.Transparency = 1
		probe.CastShadow = false
		probe.Parent = Workspace
		self.HangClearanceProbe = probe
	end
	probe.Size = root.Size + Vector3.new(0.08, 0.08, 0.08)
	probe.CFrame = target_cframe
	local overlap_params = self._hangOverlapParams or OverlapParams.new()
	self._hangOverlapParams = overlap_params
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = { character, probe }
	-- Collision filtering excludes Climbable geometry from this clearance query.
	overlap_params.CollisionGroup = "Climbable"
	overlap_params.RespectCanCollide = true

	local overlaps = Workspace:GetPartsInPart(probe, overlap_params)
	for _, part in ipairs(overlaps) do
		if part.CanCollide then
						return false, part
		end
	end

	return true
end


function ParkourController:_step(dt)
	self._stepDelta = dt

	-- Track physics top-hops so sprint remains available and the hop monitor
	-- can report landing (with a timeout guard).
	local top_hop = self._topHopActive
	if top_hop then
		local humanoid = self.Humanoid
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			top_hop.SawAir = true
		end
		local elapsed = os.clock() - top_hop.StartedAt
		local landed = top_hop.SawAir and humanoid
			and humanoid.FloorMaterial ~= Enum.Material.Air
		if landed or elapsed >= 3 then
			self:_finish_top_hop(landed)
		end
	end

	if self.State == "Grounded" then
		if self.InputController:IsDown(Actions.Jump) and not self.GrabBlockedUntilJumpReleased then
			local climbable, normal, position = self:_detect_surface()
			if climbable then self:_grab(climbable, normal, position) end
		end
	elseif self.State == "Hanging" then
		if not self.InputController:IsDown(Actions.Jump) then
			self:_release()
			return
		end
		self:_traverse(dt)
	elseif self.State == "Mantling" then
		local root = self.Root
		self._mantleElapsed = math.min((self._mantleElapsed or 0) + math.max(dt, 0), self._mantleDuration)
		local linear = self._mantleElapsed / self._mantleDuration
		local alpha = linear * linear * (3 - 2 * linear)
		if root and self._mantleStart and self._mantleTarget then
			root.CFrame = self._mantleStart:Lerp(self._mantleTarget, alpha)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
		if linear >= 1 then
			self.State = "Grounded"
			self._mantleStart = nil
			self._mantleTarget = nil
			self._mantleElapsed = nil
			self._mantleDuration = nil
			-- Restore ordinary Humanoid movement when the mantle ends. The
			-- jump/grab lock is independent and remains set until Space is released.
			if self.Humanoid then
				if self.AutoRotateBeforeHang ~= nil then self.Humanoid.AutoRotate = self.AutoRotateBeforeHang end
				if self.PlatformStandBeforeHang ~= nil then self.Humanoid.PlatformStand = self.PlatformStandBeforeHang end
				self.Humanoid:ChangeState(Enum.HumanoidStateType.Running)
			end
			self.AutoRotateBeforeHang = nil
			self.PlatformStandBeforeHang = nil
			if self.MovementController then self.MovementController:SetSprintBlocked(false, self) end
		end
	elseif self.State == "Vaulting" then
		local root = self.Root
		local duration = self._vaultDuration
		if not root or not duration or not self._vaultStart or not self._vaultTarget then
			self:_finish_vault(false)
			return
		end

		self._vaultElapsed = math.min((self._vaultElapsed or 0) + math.max(dt, 0), duration)
		local linear = self._vaultElapsed / duration
		local debug_stage = math.min(4, math.floor(linear * 4))
		if self._vaultDebugLastStage ~= debug_stage then
			self._vaultDebugLastStage = debug_stage
			vault_debug("progress", "stage=", debug_stage, "/4", "linear=", linear,
				"rootPosition=", root.Position, "targetPosition=", self._vaultTarget.Position,
				"obstacle=", self._vaultObstacle and self._vaultObstacle:GetFullName() or "nil")
		end
		local eased = linear * linear * (3 - 2 * linear)
		local base = self._vaultStart:Lerp(self._vaultTarget, eased)
		local horizontal = self._vaultStart.Position:Lerp(self._vaultTarget.Position, linear)
		local arc = vault_arc_weight(linear, self._vaultArcPeakProgress) * self._vaultArcHeight
		local position = Vector3.new(horizontal.X, base.Position.Y, horizontal.Z)
		root.CFrame = CFrame.new(position + Vector3.new(0, arc, 0)) * base.Rotation

		local vault_humanoid = self.VaultHipHeightHumanoid
		local original_hip_height = self.VaultHipHeightBefore
		if vault_humanoid and vault_humanoid.Parent and original_hip_height ~= nil then
			local reduction = math.max(0, Config.VaultHipHeightReduction or 0)
			local weight = vault_hip_height_weight(linear)
			local minimum_hip_height = 0
			if vault_humanoid.RigType == Enum.HumanoidRigType.R6 then
				-- R6 commonly starts at zero HipHeight, so allow a small negative
				-- relative offset to make the temporary crouch effective.
				minimum_hip_height = -0.35
			end
			vault_humanoid.HipHeight = math.max(
				minimum_hip_height,
				original_hip_height - reduction * weight
			)
		end

		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		if linear >= 1 then
			self:_finish_vault(true)
		end
	end
end


function ParkourController:_has_vault_clearance(cframe, size, obstacle)
	local params = self._vaultOverlapParams or OverlapParams.new()
	self._vaultOverlapParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character, obstacle }
	params.RespectCanCollide = true

	local root = self.Root
	if root then
		params.CollisionGroup = root.CollisionGroup
	end

	for _, part in ipairs(Workspace:GetPartBoundsInBox(cframe, size, params)) do
		if part.CanCollide then
			return false, part
		end
	end

	return true
end

function ParkourController:_try_vault()
	local sprinting = self.MovementController and self.MovementController:IsSprinting() or false
	vault_debug("attempt", "enabled=", Config.VaultEnabled, "state=", self.State,
		"sprinting=", sprinting, "jumpBlocked=", self.GrabBlockedUntilJumpReleased,
		"cooldownRemaining=", math.max(0, (self.NextVaultAt or 0) - os.clock()))
	if not Config.VaultEnabled then
		vault_debug("REJECT: VaultEnabled is false")
		return false
	end
	if self.State ~= "Grounded" then
		vault_debug("REJECT: character state is", self.State, "not Grounded")
		return false
	end
	if self.GrabBlockedUntilJumpReleased then
		vault_debug("REJECT: jump/grab lock is active")
		return false
	end
	if os.clock() < (self.NextVaultAt or 0) then
		vault_debug("REJECT: cooldown active")
		return false
	end
	if not self.MovementController then
		vault_debug("REJECT: MovementController missing")
		return false
	end
	if not sprinting then
		vault_debug("REJECT: not sprinting")
		return false
	end

	local now = os.clock()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root or not humanoid or humanoid.Health <= 0
		or humanoid.FloorMaterial == Enum.Material.Air then
		vault_debug("REJECT: missing/dead character or not grounded",
			"root=", root ~= nil, "humanoid=", humanoid ~= nil,
			"health=", humanoid and humanoid.Health or "nil",
			"floor=", humanoid and humanoid.FloorMaterial or "nil")
		return false
	end

	-- Follow actual movement when available, falling back to facing for the
	-- Space-press frame before Humanoid.MoveDirection has updated.
	local forward = flatten(humanoid.MoveDirection)
	local facing = flatten(root.CFrame.LookVector)
	if forward.Magnitude < 0.05 then
		forward = facing
	end
	if forward.Magnitude < 0.05 then
		vault_debug("REJECT: no movement/facing direction",
			"moveDirection=", humanoid.MoveDirection, "lookVector=", root.CFrame.LookVector)
		return false
	end
	forward = forward.Unit
	if facing.Magnitude >= 0.05 then
		facing = facing.Unit
	else
		facing = forward
	end

	local standing_height = self:_standing_height()
	local current_ground = self:_cast(
		root.Position + Vector3.new(0, 0.5, 0),
		Vector3.new(0, -(standing_height + 2), 0),
		true
	)
	if not current_ground or current_ground.Normal.Y < 0.5 then
		vault_debug("REJECT: ground probe failed",
			"origin=", root.Position + Vector3.new(0, 0.5, 0),
			"hit=", current_ground and current_ground.Instance:GetFullName() or "nil",
			"normal=", current_ground and current_ground.Normal or "nil",
			"floorMaterial=", humanoid.FloorMaterial)
		return false
	end
	vault_debug("ground OK", "part=", current_ground.Instance:GetFullName(),
		"groundY=", current_ground.Position.Y, "root=", root.Position,
		"standingHeight=", standing_height, "forward=", forward)

	local detection_origin = Vector3.new(
		root.Position.X,
		current_ground.Position.Y + Config.VaultDetectionHeight,
		root.Position.Z
	)
	local half_width = math.max(0, math.min(
		Config.VaultDetectionHalfWidth or root.Size.X * 0.5,
		math.max(root.Size.X * 0.75, 0.75)
	))
	local function probe_obstacle(direction)
		local right = direction:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			return nil
		end
		right = right.Unit
		-- Prefer the center ray: side probes are fallback coverage only, so a
		-- nearby unrelated prop cannot mask the wall directly in front.
		local center_hit = self:_cast(
			detection_origin,
			direction * Config.VaultDetectionDistance,
			true
		)
		if center_hit then
			return center_hit
		end
		local offsets = {
			right * half_width,
			-right * half_width,
			Vector3.new(0, -0.2, 0),
			Vector3.new(0, 0.45, 0),
		}
		local best_hit = nil
		for _, offset in ipairs(offsets) do
			local hit = self:_cast(
				detection_origin + offset,
				direction * Config.VaultDetectionDistance,
				true
			)
			if hit and (not best_hit or hit.Distance < best_hit.Distance) then
				best_hit = hit
			end
		end
		return best_hit
	end
	local obstacle_hit = probe_obstacle(forward)
	-- If movement is diagonal to the body's facing and its ray misses, also
	-- check the facing axis. Keep the movement vector for the vault trajectory
	-- whenever that primary probe successfully finds the obstacle.
	if not obstacle_hit and (facing - forward).Magnitude > 0.15 then
		local facing_hit = probe_obstacle(facing)
		if facing_hit then
			obstacle_hit = facing_hit
			forward = facing
		end
	end
	if not obstacle_hit then
		vault_debug("REJECT: obstacle detection missed",
			"origin=", detection_origin, "forward=", forward,
			"distance=", Config.VaultDetectionDistance,
			"halfWidth=", half_width, "facing=", facing,
			"moveDirection=", humanoid.MoveDirection)
		return false
	end

	local obstacle = obstacle_hit.Instance
	vault_debug("obstacle detected", "part=", obstacle:GetFullName(),
		"class=", obstacle.ClassName, "distance=", obstacle_hit.Distance,
		"hitPosition=", obstacle_hit.Position, "partPosition=", obstacle.Position,
		"partSize=", obstacle:IsA("BasePart") and obstacle.Size or "not BasePart",
		"canCollide=", obstacle:IsA("BasePart") and obstacle.CanCollide or false)
	if not obstacle:IsA("BasePart") or not obstacle.CanCollide
		or self:_is_climbable(obstacle) then
		vault_debug("REJECT: detected part is not a collidable, non-climbable BasePart",
			"part=", obstacle:GetFullName(), "class=", obstacle.ClassName,
			"canCollide=", obstacle:IsA("BasePart") and obstacle.CanCollide or false,
			"climbable=", self:_is_climbable(obstacle))
		return false
	end

	local obstacle_model = obstacle:FindFirstAncestorOfClass("Model")
	if obstacle_model and obstacle_model:FindFirstChildOfClass("Humanoid") then
		vault_debug("REJECT: detected obstacle belongs to a Humanoid model", obstacle_model:GetFullName())
		return false
	end

	-- Use the detected collidable part's own bounds. Its ancestor Model may
	-- be a container for an entire map, so using GetBoundingBox() there can
	-- inflate the far edge and push the landing point beyond the hop range.
	local half_depth = (
		math.abs(obstacle.CFrame.RightVector:Dot(forward)) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector:Dot(forward)) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector:Dot(forward)) * obstacle.Size.Z
	) * 0.5
	local center_distance = (obstacle.Position - root.Position):Dot(forward)
	local near_edge_distance = center_distance - half_depth
	local far_edge_distance = center_distance + half_depth
	vault_debug("obstacle projected bounds", "centerDistance=", center_distance,
		"halfDepth=", half_depth, "nearEdge=", near_edge_distance,
		"farEdge=", far_edge_distance, "hitDistance=", obstacle_hit.Distance)
	if far_edge_distance <= 0 then
		vault_debug("REJECT: projected obstacle far edge is behind/equal to root")
		return false
	end

	-- Sample the top close to the near edge, rather than aiming at the center
	-- of a long obstacle. This creates a short hop onto broad surfaces.
	local top_inset = math.min(
		Config.VaultTopLandingInset,
		math.max(0.25, half_depth * 0.75)
	)
	local top_sample_distance = near_edge_distance + top_inset
	local hit_relative = obstacle_hit.Position - root.Position
	local lateral_offset = hit_relative - forward * hit_relative:Dot(forward)
	local projected_top_sample = root.Position + forward * top_sample_distance + lateral_offset

	local top_params = self._vaultTopParams or RaycastParams.new()
	self._vaultTopParams = top_params
	top_params.FilterType = Enum.RaycastFilterType.Include
	top_params.FilterDescendantsInstances = { obstacle }
	top_params.IgnoreWater = true
	top_params.RespectCanCollide = true

	-- At oblique approaches, a wall-face hit can be near a side edge. Try
	-- vertical samples progressively inside from that exact impact point before
	-- using the projected near-edge sample; this avoids missing the top surface.
	local top_samples = {
		obstacle_hit.Position + forward * 0.25,
		obstacle_hit.Position + forward * 0.55,
		obstacle_hit.Position + forward * 0.9,
		projected_top_sample,
	}
	local top = nil
	for _, sample in ipairs(top_samples) do
		local top_origin = Vector3.new(
			sample.X,
			obstacle.Position.Y + obstacle.Size.Magnitude + 4,
			sample.Z
		)
		local candidate = Workspace:Raycast(
			top_origin,
			Vector3.new(0, -(obstacle.Size.Magnitude * 2 + 8), 0),
			top_params
		)
		if candidate and candidate.Normal.Y >= 0.5 then
			top = candidate
			break
		end
	end
	if not top then
		vault_debug("REJECT: top surface sampling failed",
			"part=", obstacle:GetFullName(), "size=", obstacle.Size,
			"partPosition=", obstacle.Position, "hitPosition=", obstacle_hit.Position,
			"testedSamples=", #top_samples)
		return false
	end

	local current_ground_y = current_ground.Position.Y
	local obstacle_height = top.Position.Y - current_ground_y
	vault_debug("top sampled", "part=", top.Instance:GetFullName(),
		"topPosition=", top.Position, "topNormal=", top.Normal,
		"groundY=", current_ground_y, "measuredHeight=", obstacle_height,
		"allowedHeight=", Config.VaultMinHeight, "to", Config.VaultMaxHeight,
		"tallThreshold=", Config.VaultFarSideOnlyHeight)
	if obstacle_height < Config.VaultMinHeight or obstacle_height > Config.VaultMaxHeight then
		vault_debug("REJECT: measured obstacle height outside configured range",
			"measuredHeight=", obstacle_height, "min=", Config.VaultMinHeight,
			"max=", Config.VaultMaxHeight)
		return false
	end

	-- Measure the part's full horizontal span, not only its thickness along
	-- the approach. Long platforms/walls use a physics-driven hop onto the
	-- sampled top instead of the scripted vault path through their geometry.
	local obstacle_lateral = Vector3.new(-forward.Z, 0, forward.X)
	local lateral_half_depth = (
		math.abs(obstacle.CFrame.RightVector:Dot(obstacle_lateral)) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector:Dot(obstacle_lateral)) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector:Dot(obstacle_lateral)) * obstacle.Size.Z
	) * 0.5
	local obstacle_length = math.max(half_depth * 2, lateral_half_depth * 2)
	local long_obstacle_threshold = Config.VaultLongObstacleHopLength or 20

	-- Detect a continuous walkable surface directly beneath the obstacle.
	-- Exclude the obstacle itself so the downward probes can reach its support
	-- floor, while retaining other world geometry in the query.
	local obstacle_vertical_half = (
		math.abs(obstacle.CFrame.RightVector.Y) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector.Y) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector.Y) * obstacle.Size.Z
	) * 0.5
	local obstacle_bottom_y = obstacle.Position.Y - obstacle_vertical_half
	local support_tolerance = math.max(0, Config.VaultGroundSupportTolerance or 0.65)
	local support_params = self._vaultSupportParams or RaycastParams.new()
	self._vaultSupportParams = support_params
	support_params.FilterType = Enum.RaycastFilterType.Exclude
	support_params.FilterDescendantsInstances = { self.Character, obstacle }
	support_params.IgnoreWater = true
	support_params.RespectCanCollide = true
	local support_origin_y = top.Position.Y + standing_height + 2
	local support_ray = Vector3.new(
		0,
		-(support_origin_y - (obstacle_bottom_y - support_tolerance)),
		0
	)
	local support_forward_offsets = { -0.65, 0, 0.65 }
	local support_lateral_offsets = { -0.8, -0.4, 0, 0.4, 0.8 }
	local support_count = 0
	local support_total = #support_forward_offsets * #support_lateral_offsets
	local support_index = 0
	local support_samples = {}
	for _, forward_factor in ipairs(support_forward_offsets) do
		for _, lateral_factor in ipairs(support_lateral_offsets) do
			support_index += 1
			local sample_position = obstacle.Position
				+ forward * (half_depth * forward_factor)
				+ obstacle_lateral * (lateral_half_depth * lateral_factor)
			local support_origin = Vector3.new(sample_position.X, support_origin_y, sample_position.Z)
			local support_hit = Workspace:Raycast(
				support_origin,
				support_ray,
				support_params
			)
			local supported = support_hit ~= nil
				and support_hit.Normal.Y >= 0.5
				and math.abs(support_hit.Position.Y - obstacle_bottom_y) <= support_tolerance
			if supported then
				support_count += 1
			end
			table.insert(support_samples, supported)
			vault_debug("ground-support probe", "index=", support_index, "/", support_total,
				"sample=", sample_position, "origin=", support_origin,
				"hit=", support_hit and support_hit.Instance:GetFullName() or "nil",
				"hitY=", support_hit and support_hit.Position.Y or "nil",
				"normalY=", support_hit and support_hit.Normal.Y or "nil",
				"bottomDelta=", support_hit and (support_hit.Position.Y - obstacle_bottom_y) or "nil",
				"supported=", supported)
		end
	end
	local has_continuous_ground_beneath = support_count == support_total
	-- Ground support alone is not enough to identify a platform: ordinary thin
	-- walls also sit on continuous floor. Require enough top depth along the
	-- travel axis for the character to land before routing a supported obstacle
	-- to the physics hop. Very long obstacles retain their dedicated hop route.
	local top_landing_depth = half_depth * 2
	local minimum_top_hop_depth = math.max(
		Config.VaultMinTopHopDepth or 2.5,
		root.Size.Z * 1.5
	)
	local has_usable_top_depth = top_landing_depth >= minimum_top_hop_depth
	local is_long_obstacle = obstacle_length >= long_obstacle_threshold
	local use_top_hop = is_long_obstacle
		or (has_continuous_ground_beneath and has_usable_top_depth)
	vault_debug("obstacle ground support summary", "part=", obstacle:GetFullName(),
		"partSize=", obstacle.Size, "lengthAlongTravel=", top_landing_depth,
		"lengthAcrossTravel=", lateral_half_depth * 2, "classifiedLength=", obstacle_length,
		"longThreshold=", long_obstacle_threshold, "bottomY=", obstacle_bottom_y,
		"tolerance=", support_tolerance, "supportHits=", support_count, "/", support_total,
		"continuous=", has_continuous_ground_beneath, "topLandingDepth=", top_landing_depth,
		"minimumTopHopDepth=", minimum_top_hop_depth, "usableTopDepth=", has_usable_top_depth,
		"route=", use_top_hop and "HOP_TO_TOP" or "VAULT_OVER")

	-- Long obstacles retain their collision-respecting physics hop. For shorter
	-- obstacles, choose the top only when continuous support and a usable top
	-- landing area are both present; thin wall-like parts use the vault-over path.
	if use_top_hop then
		vault_debug("selected top-hop route", "part=", obstacle:GetFullName(),
			"reasonLong=", is_long_obstacle,
			"reasonContinuousGround=", has_continuous_ground_beneath,
			"reasonUsableTopDepth=", has_usable_top_depth)
		local top_target = Vector3.new(
			top.Position.X,
			top.Position.Y + standing_height - 0.05,
			top.Position.Z
		)
		-- Let the Humanoid's normal sprint movement provide horizontal
		-- travel. Previously forcing a large X/Z velocity here could tunnel
		-- through broad collidable parts instead of letting physics resolve
		-- contact with their side. Set vertical speed from the exact rise to
		-- this obstacle's top, rather than using the character's default jump
		-- speed, which can launch much higher than shorter obstacles require.
		local gravity = math.max(Workspace.Gravity, 1)
		local height_margin = math.max(0, Config.VaultTopHopHeightMargin or 0.6)
		local target_rise = math.max(0, top_target.Y - root.Position.Y)
		local required_vertical_speed = math.sqrt(2 * gravity * (target_rise + height_margin))
		local current_velocity = root.AssemblyLinearVelocity
		local current_horizontal_velocity = flatten(current_velocity)
		local current_forward_speed = current_horizontal_velocity:Dot(forward)
		local is_supported_platform_hop = has_continuous_ground_beneath
			and has_usable_top_depth
			and not is_long_obstacle
		local forward_boost = is_supported_platform_hop
			and math.max(0, Config.VaultTopHopForwardBoostSpeed or 6)
			or 0
		local sprint_speed = math.max(0, humanoid.WalkSpeed)
		local hop_horizontal_velocity = current_horizontal_velocity
		if is_supported_platform_hop then
			-- Keep the existing lateral drift and ensure the character carries
			-- sprint momentum onto a supported raised surface, with a modest
			-- additional forward impulse. Long collision-sensitive obstacles
			-- intentionally retain their unboosted horizontal velocity.
			local target_forward_speed = math.max(current_forward_speed, sprint_speed) + forward_boost
			hop_horizontal_velocity += forward * (target_forward_speed - current_forward_speed)
		end
		local hop_vertical_speed = math.max(
			0,
			current_velocity.Y,
			required_vertical_speed
		)

		self.NextVaultAt = now + Config.VaultCooldown
		self.GrabBlockedUntilJumpReleased = self.InputController:IsDown(Actions.Jump)
		self._topHopActive = { StartedAt = os.clock(), SawAir = false }
		humanoid.Jump = true
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		-- Apply the calculated forward assist for supported raised surfaces;
		-- the Humanoid/physics solver still resolves collisions normally.
		root.AssemblyLinearVelocity = Vector3.new(
			hop_horizontal_velocity.X,
			hop_vertical_speed,
			hop_horizontal_velocity.Z
		)
		vault_debug("PHYSICS HOP TO TOP",
			"part=", obstacle:GetFullName(), "horizontalLength=", obstacle_length,
			"threshold=", long_obstacle_threshold, "height=", obstacle_height,
			"topTarget=", top_target, "horizontalVelocityBefore=", current_horizontal_velocity,
			"horizontalVelocityAfter=", hop_horizontal_velocity,
			"forwardBoost=", forward_boost, "heightMargin=", height_margin,
			"verticalSpeed=", hop_vertical_speed, "requiredVerticalSpeed=", required_vertical_speed,
			"customVaultAnimation=", false)
		return true
	end

	local target_position = nil
	local hop_distance = far_edge_distance + Config.VaultLandingGap
	local landing_origin_y = math.max(root.Position.Y, top.Position.Y)
		+ standing_height + Config.VaultMaxHeight + 2
	-- The origin rises with the obstacle top. A fixed ray length can therefore
	-- stop at (or above) the starting floor for taller walls, making every
	-- far-side probe miss otherwise valid ground. Extend below the known floor
	-- by the landing-height tolerance plus a safety margin.
	local landing_ray = Vector3.new(
		0,
		-(landing_origin_y - current_ground_y + Config.VaultLandingHeightTolerance + 1),
		0
	)
	vault_debug("landing ray range", "originY=", landing_origin_y,
		"length=", -landing_ray.Y, "knownGroundY=", current_ground_y,
		"rayEndY=", landing_origin_y + landing_ray.Y)
	local hit_relative = obstacle_hit.Position - root.Position
	-- Continue along the exact lane that detected the obstacle. Side probes
	-- can hit a wall away from the character's centerline, so dropping this
	-- offset would aim the far-side landing back into the wall footprint.
	local landing_lateral = flatten(hit_relative) - forward * flatten(hit_relative):Dot(forward)
	local function is_obstacle_part(instance)
		-- Exclude only the actual hit part. Its ancestor Model may also contain
		-- legitimate floor geometry used by the far-side landing ray.
		return instance == obstacle
	end

	-- Prefer ground beyond the far edge. Begin with nearby probes, then
	-- continue through the remaining hop budget. The detected part can be only
	-- one segment of a wider wall, so a fixed six-stud search can stop before
	-- reaching the actual far side and incorrectly reject every tall-wall vault.
	local landing_extra_distances = { 0, 0.75, 1.5, 2.5, 4, 6 }
	local max_landing_extra = math.max(0, Config.VaultMaxHopDistance - hop_distance)
	local next_landing_extra = 6.75
	while next_landing_extra < max_landing_extra do
		table.insert(landing_extra_distances, next_landing_extra)
		next_landing_extra += 0.75
	end
	local has_limit_probe = false
	for _, extra_distance in ipairs(landing_extra_distances) do
		if math.abs(extra_distance - max_landing_extra) < 1e-4 then
			has_limit_probe = true
			break
		end
	end
	if max_landing_extra > 0 and not has_limit_probe then
		table.insert(landing_extra_distances, max_landing_extra)
	end

	local landing_stats = { probes = 0, overRange = 0, noHit = 0, steep = 0, wrongHeight = 0, obstaclePart = 0 }
	local last_landing_hit = nil
	for _, extra_distance in ipairs(landing_extra_distances) do
		local landing_distance = hop_distance + extra_distance
		if landing_distance <= Config.VaultMaxHopDistance then
			for _, lateral_adjustment in ipairs({ 0, -0.75, 0.75 }) do
				local side = forward:Cross(Vector3.yAxis)
				local landing_xz = root.Position + forward * landing_distance + landing_lateral
				if side.Magnitude > 0.05 then
					landing_xz += side.Unit * lateral_adjustment
				end
				-- Enforce the cap on the real horizontal displacement too;
				-- the lateral fan otherwise adds a small amount beyond 24 studs.
				local actual_hop_distance = flatten(landing_xz - root.Position).Magnitude
				if actual_hop_distance <= Config.VaultMaxHopDistance + 1e-4 then
					landing_stats.probes += 1
					local landing_ground = self:_cast(
						Vector3.new(landing_xz.X, landing_origin_y, landing_xz.Z),
						landing_ray,
						true
					)
					if not landing_ground then
						landing_stats.noHit += 1
					else
						last_landing_hit = landing_ground
						if landing_ground.Normal.Y < 0.5 then
							landing_stats.steep += 1
						elseif math.abs(landing_ground.Position.Y - current_ground_y) > Config.VaultLandingHeightTolerance then
							landing_stats.wrongHeight += 1
						elseif is_obstacle_part(landing_ground.Instance) then
							landing_stats.obstaclePart += 1
						else
							target_position = Vector3.new(
								landing_ground.Position.X,
								landing_ground.Position.Y + standing_height - 0.05,
								landing_ground.Position.Z
							)
							vault_debug("far-side landing found", "groundPart=", landing_ground.Instance:GetFullName(),
								"groundPosition=", landing_ground.Position, "normal=", landing_ground.Normal,
								"heightDelta=", landing_ground.Position.Y - current_ground_y,
								"requestedDistance=", landing_distance, "actualDistance=", actual_hop_distance,
								"extra=", extra_distance, "lateralAdjustment=", lateral_adjustment)
							break
						end
					end
				else
					landing_stats.overRange += 1
				end
			end
			if target_position then
				break
			end
		end
	end

	-- Taller walls should be cleared rather than converted into a hop onto
	-- their top. If safe far-side ground is unavailable, decline that vault
	-- instead of silently changing its destination.
	if not target_position
		and obstacle_height >= (Config.VaultFarSideOnlyHeight or math.huge) then
		vault_debug("REJECT: tall obstacle has no validated far-side landing",
			"height=", obstacle_height, "threshold=", Config.VaultFarSideOnlyHeight,
			"farEdge=", far_edge_distance, "landingGap=", Config.VaultLandingGap,
			"initialHopDistance=", hop_distance, "maxHop=", Config.VaultMaxHopDistance,
			"landingProbeCount=", landing_stats.probes,
			"overRange=", landing_stats.overRange, "noHit=", landing_stats.noHit,
			"steep=", landing_stats.steep, "wrongHeight=", landing_stats.wrongHeight,
			"hitObstaclePart=", landing_stats.obstaclePart,
			"lastGroundHit=", last_landing_hit and last_landing_hit.Instance:GetFullName() or "nil",
			"lastHitPosition=", last_landing_hit and last_landing_hit.Position or "nil",
			"lastHitNormal=", last_landing_hit and last_landing_hit.Normal or "nil")
		return false
	end

	-- Preserve the short top landing for lower, broad obstacles when no
	-- validated far-side floor is available.
	if not target_position then
		target_position = Vector3.new(
			top.Position.X,
			top.Position.Y + standing_height - 0.05,
			top.Position.Z
		)
	end

	local start_cframe = root.CFrame
	local target_cframe = CFrame.lookAt(target_position, target_position + forward)
	local midpoint_y = (start_cframe.Position.Y + target_cframe.Position.Y) * 0.5
	local horizontal_vault_distance = math.max(
		flatten(target_position - start_cframe.Position):Dot(forward),
		0.1
	)
	-- Place the apex above the obstacle's center, even when the vault begins
	-- several studs before it because of the longer detection range.
	local tall_height_factor = math.clamp(obstacle_height - 2, 0, 2)
	local arc_peak_progress = math.clamp(
		center_distance / horizontal_vault_distance - tall_height_factor * 0.06,
		0.2,
		0.92
	)
	-- Taller walls get an earlier lift and extra apex clearance so the root
	-- collider clears the face before the forward trajectory reaches it.
	local tall_obstacle_clearance = tall_height_factor
		* math.max(0, Config.VaultTallObstacleClearancePerStud or 0)
	local required_apex_y = top.Position.Y + root.Size.Y * 0.5
		+ Config.VaultObstacleClearance + tall_obstacle_clearance
	local arc_height = math.max(Config.VaultMinArcHeight, required_apex_y - midpoint_y)
	vault_debug("trajectory planned", "target=", target_position,
		"hopDistance=", flatten(target_position - root.Position).Magnitude,
		"arcHeight=", arc_height, "maxArc=", Config.VaultMaxArcHeight,
		"arcPeak=", arc_peak_progress, "requiredApexY=", required_apex_y,
		"tallClearance=", tall_obstacle_clearance, "durationFactor=", tall_height_factor)
	if arc_height > Config.VaultMaxArcHeight then
		vault_debug("REJECT: required arc exceeds configured maximum",
			"arcHeight=", arc_height, "maxArc=", Config.VaultMaxArcHeight,
			"obstacleTopY=", top.Position.Y, "rootY=", root.Position.Y,
			"rootSizeY=", root.Size.Y, "midpointY=", midpoint_y)
		return false
	end

	-- Reject low ceilings and blocked landing space before committing.
	local clearance_size = Vector3.new(
		root.Size.X + 0.5,
		math.max(root.Size.Y + 0.25, standing_height * 1.6),
		root.Size.Z + 0.5
	)
	for _, alpha in ipairs({ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1 }) do
		local eased = alpha * alpha * (3 - 2 * alpha)
		local base = start_cframe:Lerp(target_cframe, eased)
		local horizontal = start_cframe.Position:Lerp(target_cframe.Position, alpha)
		local arc = vault_arc_weight(alpha, arc_peak_progress) * arc_height
		local sample_position = Vector3.new(horizontal.X, base.Position.Y, horizontal.Z)
		local sample_cframe = CFrame.new(
			sample_position + Vector3.new(0, arc, 0)
		) * base.Rotation
		local clear, blocker = self:_has_vault_clearance(sample_cframe, clearance_size, obstacle)
		if not clear then
			vault_debug("REJECT: trajectory clearance blocked", "alpha=", alpha,
				"samplePosition=", sample_cframe.Position,
				"blocker=", blocker and blocker:GetFullName() or "unknown",
				"blockerPosition=", blocker and blocker.Position or "unknown",
				"obstacle=", obstacle:GetFullName())
			return false
		end
	end

	-- Script the vault arc, then hand the player back the forward speed they
	-- had while sprinting. Humanoid.WalkSpeed is captured before sprint is
	-- temporarily blocked; actual momentum above that speed is preserved.
	local horizontal_velocity = flatten(root.AssemblyLinearVelocity)
	local forward_speed = horizontal_velocity:Dot(forward)
	local sprint_speed = math.max(0, humanoid.WalkSpeed)
	if forward_speed < sprint_speed then
		horizontal_velocity += forward * (sprint_speed - forward_speed)
	end
	local forward_boost = math.max(0, Config.VaultForwardBoostSpeed or 0)
	horizontal_velocity += forward * forward_boost
	-- Scale the scripted traversal time to the active sprint speed. A small
	-- floor keeps very short vaults from snapping, while longer hops retain
	-- approximately the same horizontal pace as the approach.
	local vault_distance = (target_position - start_cframe.Position).Magnitude
	local vault_duration = Config.VaultDuration
	local vault_speed = sprint_speed + forward_boost
	if vault_speed > 0.1 then
		vault_duration = math.max(0.2, vault_distance / vault_speed)
	end
	-- Add airtime only for taller walls; low vaults retain their existing pace.
	vault_duration += tall_height_factor
		* math.max(0, Config.VaultTallDurationPerStud or 0)
	vault_duration *= math.clamp(Config.VaultDurationMultiplier or 1, 0.5, 1.5)

	self.NextVaultAt = now + Config.VaultCooldown
	self._vaultExitVelocity = horizontal_velocity
	self._vaultStart = start_cframe
	self._vaultTarget = target_cframe
	self._vaultElapsed = 0
	self._vaultDuration = vault_duration
	self._vaultArcHeight = arc_height
	self._vaultArcPeakProgress = arc_peak_progress
	self._vaultObstacle = obstacle
	self.VaultAutoRotateBefore = humanoid.AutoRotate
	self.VaultPlatformStandBefore = humanoid.PlatformStand
	self.VaultHipHeightBefore = humanoid.HipHeight
	self.VaultHipHeightHumanoid = humanoid
	self.VaultJumpingEnabledBefore = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	self.GrabBlockedUntilJumpReleased = self.InputController:IsDown(Actions.Jump)

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid.Jump = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	self.State = "Vaulting"
	self.MovementController:SetSprintBlocked(true, self)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	vault_debug("VAULT STARTED", "obstacle=", obstacle:GetFullName(),
		"height=", obstacle_height, "target=", target_position,
		"duration=", vault_duration, "arcHeight=", arc_height)
	return true
end

function ParkourController:_finish_top_hop(landed)
	local top_hop = self._topHopActive
	if not top_hop then
		return
	end
	self._topHopActive = nil
	vault_debug("TOP HOP FINISHED", "landed=", landed,
		"duration=", os.clock() - top_hop.StartedAt,
		"rootPosition=", self.Root and self.Root.Position or "nil")
end

function ParkourController:_finish_vault(completed)
	if self.State ~= "Vaulting" then
		return
	end

	vault_debug("VAULT FINISHED", "completed=", completed,
		"rootPosition=", self.Root and self.Root.Position or "nil",
		"targetPosition=", self._vaultTarget and self._vaultTarget.Position or "nil",
		"obstacle=", self._vaultObstacle and self._vaultObstacle:GetFullName() or "nil")
	self._vaultDebugLastStage = nil
	self.State = "Grounded"
	local exit_velocity = self._vaultExitVelocity
	self._vaultExitVelocity = nil
	self._vaultStart = nil
	self._vaultTarget = nil
	self._vaultElapsed = nil
	self._vaultDuration = nil
	self._vaultArcHeight = nil
	self._vaultArcPeakProgress = nil
	self._vaultObstacle = nil

	local humanoid = self.Humanoid
	local hip_height_humanoid = self.VaultHipHeightHumanoid
	local original_hip_height = self.VaultHipHeightBefore
	if hip_height_humanoid and hip_height_humanoid.Parent and original_hip_height ~= nil then
		hip_height_humanoid.HipHeight = original_hip_height
	end
	self.VaultHipHeightHumanoid = nil
	self.VaultHipHeightBefore = nil

	if completed and self.InputController:IsDown(Actions.Jump) then
		self.GrabBlockedUntilJumpReleased = true
	end
	if not completed then
		self.GrabBlockedUntilJumpReleased = false
	end

	if humanoid and humanoid.Parent then
		if self.VaultAutoRotateBefore ~= nil then
			humanoid.AutoRotate = self.VaultAutoRotateBefore
		end
		if self.VaultPlatformStandBefore ~= nil then
			humanoid.PlatformStand = self.VaultPlatformStandBefore
		end
		humanoid.Jump = false

		if self.VaultJumpingEnabledBefore ~= nil and not self.GrabBlockedUntilJumpReleased then
			humanoid:SetStateEnabled(
				Enum.HumanoidStateType.Jumping,
				self.VaultJumpingEnabledBefore
			)
			self.VaultJumpingEnabledBefore = nil
		end

		if completed and humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end

	self.VaultAutoRotateBefore = nil
	self.VaultPlatformStandBefore = nil
	if not self.GrabBlockedUntilJumpReleased then
		self.VaultJumpingEnabledBefore = nil
	end
	if self.MovementController then
		self.MovementController:SetSprintBlocked(false, self)
	end

	-- The scripted CFrame path zeroes physics velocity while airborne. Restore
	-- horizontal sprint momentum at the landing handoff so the vault does not
	-- leave the character stationary; preserve any vertical landing velocity.
	local root = self.Root
	if completed and root and root.Parent and exit_velocity then
		local vertical_velocity = root.AssemblyLinearVelocity.Y
		root.AssemblyLinearVelocity = Vector3.new(
			exit_velocity.X,
			vertical_velocity,
			exit_velocity.Z
		)
	end
end


function ParkourController:_get_traverse_speed()
	local speed = Config.TraverseSpeed
	if self.InputController:IsDown(Actions.Sprint) then
		speed *= Config.TraverseSprintMultiplier
	end
	return speed
end

function ParkourController:_snapshot_hang_pose()
	local root = self.Root
	return {
		CurrentClimbable = self.CurrentClimbable,
		Normal = self.Normal,
		HangDepthOffset = self.HangDepthOffset,
		HangPosition = self.HangPosition,
		CornerLockPosition = self.CornerLockPosition,
		CornerLockInputDirection = self.CornerLockInputDirection,
		CFrame = root and root.CFrame,
	}
end

function ParkourController:_restore_hang_pose(snapshot)
	self.CurrentClimbable = snapshot.CurrentClimbable
	self.Normal = snapshot.Normal
	self.HangDepthOffset = snapshot.HangDepthOffset
	self.HangPosition = snapshot.HangPosition
	self.CornerLockPosition = snapshot.CornerLockPosition
	self.CornerLockInputDirection = snapshot.CornerLockInputDirection
	local root = self.Root
	if root and snapshot.CFrame then
		root.CFrame = snapshot.CFrame
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

function ParkourController:_traverse(dt)
	local root = self.Root
	local climbable = self.CurrentClimbable
	local normal = self.Normal
	if not root or not climbable or not normal or not climbable:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	local active_top_y = self.HangPosition.Y + Config.HangDrop

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		local pose_snapshot = self:_snapshot_hang_pose()
		local tangent = flatten(root.CFrame.RightVector)
		if tangent.Magnitude < 0.05 then
			tangent = flatten(Vector3.yAxis:Cross(normal))
		end
		if tangent.Magnitude < 0.05 then
			self:_position_hanging()
			return
		end
		tangent = tangent.Unit

		-- Roblox cylinders run along local X. For an upright cylinder that
		-- axis is vertical; the previous predicate accidentally selected a
		-- horizontal cylinder and skipped the common upright case.
		local cylinder = climbable:IsA("BasePart")
			and climbable.Shape == Enum.PartType.Cylinder
			and math.abs(climbable.CFrame.RightVector.Y) >= 0.75
			and climbable
		if cylinder then
			local axis = cylinder.CFrame.RightVector
			local center = cylinder.Position
			local radial = flatten(root.Position - center)
			if radial.Magnitude < 0.05 then
				radial = -flatten(normal)
			end
			if radial.Magnitude >= 0.05 then
				radial = radial.Unit
				local radius = math.max(cylinder.Size.Y, cylinder.Size.Z) * 0.5
				local arc = self:_get_traverse_speed() * math.max(dt, 0)
				local angular_tangent = flatten(Vector3.yAxis:Cross(radial))
				local travel_tangent = tangent * direction
				local turn_sign = angular_tangent:Dot(travel_tangent) >= 0 and 1 or -1
				local angle = arc / math.max(radius + Config.WallGap, 0.1) * turn_sign
				local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(radial)
				local sample = center + rotated * radius
				local top = self:_get_guide_top(climbable, sample)
				if top and top.Normal.Y >= 0.5 then
					local next_normal = flatten(sample - center)
					if next_normal.Magnitude >= 0.05 then
						next_normal = next_normal.Unit
						local next_position = Vector3.new(top.Position.X, self.HangPosition.Y, top.Position.Z)
							+ next_normal * Config.WallGap
						local clear = self:_has_hang_body_clearance(next_position, next_normal)
						if clear then
							self.Normal = next_normal
							self.HangDepthOffset = next_normal * Config.WallGap
							self.HangPosition = next_position
						else
							self:_restore_hang_pose(pose_snapshot)
						end
					end
				end
			end
			self:_position_hanging()
			return
		end

		-- During a smoothed W/S transfer, root.Position is intentionally between
		-- the source and destination heights. Lateral contact probes must use
		-- the logical hang target so they sample the destination ledge consistently.
		local candidate_position = self.HangPosition
			+ tangent * direction * self:_get_traverse_speed() * math.max(dt, 0)
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = self:_cast(
			probe_origin,
			-normal * (Config.WallGap + Config.SurfaceProbe)
		)
		local top = probe
			and self:_cast_reachable_grab_top(probe.Position, probe.Normal, candidate_position, active_top_y)
		local next_climbable = top
			and self:_get_climbable_guide(top.Instance)
		local same_height = top
			and math.abs(top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
			and top.Normal.Y >= 0.5
		local horizontal_normal = probe and flatten(probe.Normal) or Vector3.zero

		-- Probe a wider corner fan when the character reaches a corner. Both
		-- handednesses are considered because a route may wrap around either
		-- a convex outside corner or a concave inside corner.
		local movement_tangent = tangent * direction
		local corner_locked = false
		if self.CornerLockPosition then
			corner_locked = flatten(root.Position - self.CornerLockPosition).Magnitude < Config.CornerLockDistance
			if self.CornerLockInputDirection
				and direction ~= self.CornerLockInputDirection then
				-- An intentional left/right reversal means the player wants to
				-- turn back now. Drop the seam lock immediately; same-direction
				-- movement remains locked until the character clears the corner.
				corner_locked = false
				self.CornerLockPosition = nil
				self.CornerLockInputDirection = nil
			elseif not corner_locked then
				self.CornerLockPosition = nil
				self.CornerLockInputDirection = nil
			end
		end
		local corner_turn_normals = {}
		if not corner_locked then
			-- The face facing the direction of travel is preferred. The opposite
			-- face remains a fallback for concave layouts, not an equal candidate.
			corner_turn_normals = { movement_tangent, -movement_tangent }
		end
		local corner_longitudinal_offsets = {
			-normal * 1.8,
			-normal * 0.9,
			normal * 0.9,
			normal * 1.8,
		}
		local best_corner = nil
		local best_corner_score = math.huge
		local corner_clearance = math.max(root.Size.X, root.Size.Z) * 0.5 + 0.1

		for _, turn_normal in ipairs(corner_turn_normals) do
			for _, longitudinal_offset in ipairs(corner_longitudinal_offsets) do
				local corner_origin = candidate_position
					+ Vector3.new(0, 1.5, 0)
					+ longitudinal_offset
					+ turn_normal * (Config.WallGap + 0.75)
				local corner_probe = self:_cast_climbable_side(
					corner_origin,
					-turn_normal * (Config.WallGap + Config.SurfaceProbe + 2)
				)
				if corner_probe then
					local corner_normal = flatten(corner_probe.Normal)
					if corner_normal.Magnitude >= 0.05 then
						corner_normal = corner_normal.Unit
						local alignment_to_old = math.abs(corner_normal:Dot(normal))
						local alignment_to_turn = corner_normal:Dot(turn_normal)
						local along_movement = flatten(corner_probe.Position - candidate_position):Dot(movement_tangent)
						local perpendicular = alignment_to_old <= 0.45
							and alignment_to_turn >= 0.55
						local near_corner = along_movement >= -1.5
							and along_movement <= Config.WallGap + Config.SurfaceProbe + 1.5

						if perpendicular and near_corner then
							local corner_top = self:_cast_reachable_grab_top(
								corner_probe.Position,
								corner_probe.Normal,
								root.Position,
								root.Position.Y + Config.HangDrop
							)
							local corner_guide = corner_top
								and self:_get_climbable_guide(corner_top.Instance)
							local corner_height_ok = corner_top
								and math.abs(corner_top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
								and corner_top.Normal.Y >= 0.5

							if corner_top and corner_guide and corner_height_ok then
								-- The root is centered at the corner seam after a 90-degree
								-- turn, so its body can still overlap the old wall. Move one
								-- half-root-width along the old wall's outward axis, then
								-- confirm that the destination guide actually covers that
								-- landing column before accepting the corner.
								local cleared_sample = corner_top.Position + normal * corner_clearance
								local cleared_top = nil
								local cleared_distance = math.huge
								for _, candidate_top in ipairs(self:_get_guide_tops(corner_guide, cleared_sample)) do
									local distance = math.abs(candidate_top.Position.Y - active_top_y)
									if distance < cleared_distance then
										cleared_top = candidate_top
										cleared_distance = distance
									end
								end
								local clearance_valid = cleared_top
									and cleared_distance <= Config.TraverseHeightTolerance
									and flatten(cleared_top.Position - cleared_sample).Magnitude <= 1.25
								if clearance_valid then
									local candidate_hang = cleared_top.Position
										+ corner_normal * Config.WallGap
										- Vector3.new(0, Config.HangDrop, 0)
									local candidate_clear = self:_has_hang_body_clearance(candidate_hang, corner_normal)
									if candidate_clear then
									local turn_side_penalty = turn_normal:Dot(movement_tangent) >= 0 and 0 or 100
									local score = turn_side_penalty
										+ math.abs(along_movement)
										+ alignment_to_old * 2
										+ math.abs(longitudinal_offset.Magnitude) * 0.05
									if score < best_corner_score then
										best_corner = {
											Top = cleared_top,
											Guide = corner_guide,
											Normal = corner_normal,
											WallInstance = corner_probe.Instance,
										}
										best_corner_score = score
									end
									end
								end
							end
						end
					end
				end
			end
		end

		local is_corner_transfer = best_corner ~= nil
		if is_corner_transfer then
			top = best_corner.Top
			next_climbable = best_corner.Guide
			same_height = true
			horizontal_normal = best_corner.Normal
					end

		if horizontal_normal.Magnitude >= 0.05 then
			horizontal_normal = horizontal_normal.Unit
		else
			horizontal_normal = normal
		end
		-- A normal side-ray can still see the previous wall at the corner seam.
		-- Never let that stale face overwrite an already-acquired perpendicular
		-- face; only a validated corner probe may rotate the hanging normal.
		local probe_normal_aligned = horizontal_normal:Dot(normal) >= 0.65

		if top and next_climbable == climbable and same_height
			and (is_corner_transfer or probe_normal_aligned) then
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * Config.WallGap
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		elseif top and next_climbable and next_climbable ~= climbable and same_height
			and (is_corner_transfer or probe_normal_aligned) then
			self.CurrentClimbable = next_climbable
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * Config.WallGap
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		else
					end

		-- Exempt only the exact wall part supporting the hang; the top is below the root by Config.HangDrop and must not mask a thick-wall collision.
		local pose_changed = (self.HangPosition - pose_snapshot.HangPosition).Magnitude > 1e-3
			or self.Normal:Dot(pose_snapshot.Normal) < 0.999
		local midpoint_clear = true
		if is_corner_transfer and self.Normal:Dot(pose_snapshot.Normal) < 0.707 then
			local midpoint = pose_snapshot.HangPosition:Lerp(self.HangPosition, 0.5)
			local midpoint_normal = flatten(pose_snapshot.Normal + self.Normal)
			if midpoint_normal.Magnitude < 0.05 then midpoint_normal = self.Normal end
			midpoint_clear = self:_has_hang_body_clearance(midpoint, midpoint_normal)
		end
		local body_clear = not pose_changed or (midpoint_clear and self:_has_hang_body_clearance(self.HangPosition, self.Normal))
		if not body_clear then
			self:_restore_hang_pose(pose_snapshot)
		else
			if is_corner_transfer then
				self.CornerLockPosition = self.HangPosition
				self.CornerLockInputDirection = direction
			end
		end
	end

	self:_position_hanging()
end


function ParkourController:_try_lower_ledge()
		if self.State ~= "Hanging" or not self.Root or not self.CurrentClimbable
		or not self.HangPosition or not self.Normal then
				return
	end

	local root = self.Root
	local normal = flatten(self.Normal)
	if normal.Magnitude < 0.05 then
				return
	end
	normal = normal.Unit

	local tangent = flatten(root.CFrame.RightVector)
	if tangent.Magnitude < 0.05 then
		tangent = flatten(Vector3.yAxis:Cross(normal))
	end
	if tangent.Magnitude < 0.05 then
				return
	end
	tangent = tangent.Unit

	local current_top = self.HangPosition - normal * Config.WallGap + Vector3.new(0, Config.HangDrop, 0)
	local best_top = nil
	local best_drop = math.huge
	local best_distance = math.huge

	-- Search nearby columns and every exposed walkable surface on each tagged
	-- guide. This also supports multi-part tagged models with several stacked
	-- ledges, where the model's single bounding-box top hides lower surfaces.
	local lateral_samples = { 0, -1.5, 1.5, -3, 3, -4.5, 4.5 }
	local inward_samples = { 0, 1.5, 3, 5 }
	local function consider_lower_top(guide, top)
		if not top or top.Normal.Y < 0.5 then return end
		local relative = top.Position - current_top
		local drop = current_top.Y - top.Position.Y
		local inward = relative:Dot(-normal)
		-- The ray hit proves this exact column is supported. Measure its
		-- actual offset from the player's ledge instead of subtracting a
		-- model-wide half extent that changes when another child is resized.
		local lateral_gap = math.abs(flatten(relative):Dot(tangent))
		local in_vertical_range = drop >= 0.5 and drop <= Config.MantleMaxRise
		local in_reach = inward >= -Config.MantleMaxOutward
			and inward <= Config.MantleMaxInward
			and lateral_gap <= Config.MantleMaxLateral

		if in_vertical_range and in_reach then
			local target_top_position = top.Position
			local horizontal_distance = flatten(target_top_position - current_top).Magnitude
			if drop < best_drop or (math.abs(drop - best_drop) < 1e-4 and horizontal_distance < best_distance) then
				best_top = top
				best_drop = drop
				best_distance = horizontal_distance
			end
		end
	end

	-- S transfers only to a lower tagged guide/surface. It does not dismount to
	-- ordinary ground; W remains the upper-ground mantle action.
	for _, guide in ipairs(CollectionService:GetTagged(Config.ClimbableTag)) do
		if guide:IsDescendantOf(Workspace)
			and self:_is_guide_within_mantle_search(guide, current_top, normal, tangent) then
			for _, lateral_offset in ipairs(lateral_samples) do
				for _, inward_offset in ipairs(inward_samples) do
					local sample_position = current_top
						+ tangent * lateral_offset
						- normal * inward_offset
					for _, top in ipairs(self:_get_guide_tops(guide, sample_position)) do
						consider_lower_top(guide, top)
					end
				end
			end
		end
	end

	if not best_top then
				return
	end

	-- best_top is already the actual exposed lower surface hit at the
	-- selected column. Do not replace it with _get_guide_top here: that returns
	-- the highest surface in a stacked Model and can undo the lower selection.
	local target_normal = self:_get_ledge_outward_normal(best_top, root.Position)
	if target_normal then
			else
		-- Preserve the existing face if the destination has no detectable
		-- climbable side surface at the character's hang height.
		target_normal = normal
			end
		self:_transfer_hang_to_ledge(best_top, target_normal)
end

function ParkourController:_standing_height()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root then return 3 end

	local hip_height = humanoid and humanoid.HipHeight or 2
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
		-- R6's HipHeight does not include the leg length needed to place the
		-- root at its normal standing height. Include one extra root height.
		return hip_height + root.Size.Y * 1.5
	end

	return hip_height + root.Size.Y * 0.5
end

function ParkourController:_refresh_hang_contact(expected_guide, expected_top_y)
	local root = self.Root
	local normal = self.Normal
	local candidate_position = root and self.HangPosition
	if not root or not normal or not candidate_position or not expected_guide then
		return false
	end

	-- Use the same local side probe as A/D traversal immediately after a
	-- vertical transfer. The destination top-center sample alone can leave
	-- the root a few tenths off the actual wall contact; lateral input used
	-- to correct this on the next Heartbeat.
	local probe_origin = candidate_position
		+ Vector3.new(0, 1.5, 0)
		+ normal * 0.3
	local probe = self:_cast(
		probe_origin,
		-normal * (Config.WallGap + Config.SurfaceProbe)
	)
	if not probe then
		return false
	end

	local top = self:_cast_reachable_grab_top(probe.Position, probe.Normal, candidate_position, candidate_position.Y + Config.HangDrop)
	if not top or self:_get_climbable_guide(top.Instance) ~= expected_guide then
		return false
	end
	if expected_top_y and math.abs(top.Position.Y - expected_top_y) > Config.TraverseHeightTolerance then
		return false
	end

	local horizontal_normal = flatten(probe.Normal)
	if horizontal_normal.Magnitude < 0.05 then
		return false
	end
	horizontal_normal = horizontal_normal.Unit

	-- Match the successful A/D contact correction exactly: anchor X/Z to the
	-- locally sampled top/wall, retain the selected hang height, and face the
	-- actual wall normal. This runs synchronously within W/S, so no sideways
	-- input is needed to settle the character.
	self.Normal = horizontal_normal
	self.HangDepthOffset = horizontal_normal * Config.WallGap
	self.HangPosition = Vector3.new(
		top.Position.X,
		candidate_position.Y,
		top.Position.Z
	) + self.HangDepthOffset
	return true
end

function ParkourController:_get_ledge_outward_normal(top, reference_position)
	if not top or not top.Instance or not top.Instance:IsA("BasePart") then
		return nil
	end

	local part = top.Instance
	local guide = top.Guide or self:_get_climbable_guide(part)
	if not guide then return nil end

	-- The top surface normal is vertical and cannot tell us which vertical
	-- face the destination ledge presents. Probe outward from the actual
	-- sampled part along its local horizontal face axes and world axes; the
	-- raycast's side normal identifies the face that is exposed to the player.
	local axes = {}
	local function add_axis(axis)
		local horizontal = flatten(axis)
		if horizontal.Magnitude < 0.05 then return end
		horizontal = horizontal.Unit
		for _, existing in ipairs(axes) do
			if math.abs(existing:Dot(horizontal)) > 0.98 then
				return
			end
		end
		table.insert(axes, horizontal)
		table.insert(axes, -horizontal)
	end

	add_axis(part.CFrame.RightVector)
	add_axis(part.CFrame.UpVector)
	add_axis(part.CFrame.LookVector)
	add_axis(Vector3.xAxis)
	add_axis(Vector3.zAxis)

	local probe_length = Config.WallGap + Config.SurfaceProbe + 2
	local probe_y = top.Position.Y - Config.HangDrop + 1.5
	local best_normal = nil
	local best_score = math.huge
	for _, outward in ipairs(axes) do
		local origin = Vector3.new(top.Position.X, probe_y, top.Position.Z)
			+ outward * probe_length
		local hit = self:_cast_climbable_side(origin, -outward * probe_length)
		if hit and self:_get_climbable_guide(hit.Instance) == guide then
			local face_normal = flatten(hit.Normal)
			if face_normal.Magnitude >= 0.05 then
				face_normal = face_normal.Unit
				local face_alignment = face_normal:Dot(outward)
				if face_alignment >= 0.5 then
					local toward_player = flatten(reference_position - hit.Position)
					local player_alignment = 0
					if toward_player.Magnitude >= 0.05 then
						player_alignment = math.max(0, face_normal:Dot(toward_player.Unit))
					end
					local distance = flatten(reference_position - hit.Position).Magnitude
					local score = distance + (1 - player_alignment) * 1.5
					if score < best_score then
						best_score = score
						best_normal = face_normal
					end
				end
			end
		end
	end

	return best_normal
end


function ParkourController:_transfer_hang_to_ledge(top, target_normal)
	local root = self.Root
	local normal = self.Normal
	if not root or not top or not normal then return false end

	local destination_normal = flatten(target_normal or normal)
	if destination_normal.Magnitude < 0.05 then return false end
	destination_normal = destination_normal.Unit

	-- W/S change ledge height. Begin with the cached hang transform, then
	-- immediately resolve the destination's actual side/top contact using the
	-- same probe that has been correcting the position during A/D traversal.
	local depth_offset = self.HangDepthOffset
	if target_normal then
		-- A vertical transfer may land on a ledge whose wall faces another
		-- direction. Use its detected destination normal for both facing and
		-- stand-off depth instead of carrying the source wall's cached offset.
		depth_offset = destination_normal * Config.WallGap
	elseif not depth_offset or flatten(depth_offset).Magnitude < 0.05 then
		depth_offset = destination_normal * Config.WallGap
	end
	local target_guide = top.Guide or self:_get_climbable_guide(top.Instance)
	if not target_guide then return false end

	local planned_position = top.Position
		+ depth_offset
		- Vector3.new(0, Config.HangDrop, 0)
	local planned_clear, planned_blocker = self:_has_hang_body_clearance(
		planned_position,
		destination_normal
	)
	if not planned_clear then
				return false
	end

	local pose_snapshot = self:_snapshot_hang_pose()
	self.State = "Hanging"
	self.CurrentClimbable = target_guide
	self.Normal = destination_normal
	self.HangDepthOffset = depth_offset
	self.HangPosition = top.Position
		+ depth_offset
		- Vector3.new(0, Config.HangDrop, 0)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	-- Resolve the destination wall contact before moving the character. The
	-- sampled top can be laterally offset from the actual wall face; placing
	-- the root at this provisional pose first causes a visible/physical nudge
	-- into the ledge during simultaneous sideways and vertical input.
	local refreshed = self:_refresh_hang_contact(target_guide, top.Position.Y)
	if not refreshed then
		self:_restore_hang_pose(pose_snapshot)
		return false
	end
		local final_clear, final_blocker = self:_has_hang_body_clearance(
		self.HangPosition,
		self.Normal
	)
	if not final_clear then
		self:_restore_hang_pose(pose_snapshot)
				return false
	end
	self:_position_hanging()
		return true
end


function ParkourController:_get_guide_top(guide, sample_position)
	local box_cframe
	local box_size
	local hit_instance
	if guide:IsA("BasePart") then
		box_cframe = guide.CFrame
		box_size = guide.Size
		hit_instance = guide
	elseif guide:IsA("Model") then
		box_cframe, box_size = guide:GetBoundingBox()
		hit_instance = guide.PrimaryPart or guide:FindFirstChildWhichIsA("BasePart", true)
	else
		return nil
	end
	if not hit_instance then return nil end

	-- Sample the actual highest walkable surface at the guide's horizontal
	-- center. This handles cylinders whose long axis is local X, including
	-- cylinders rotated upright, without assuming local Y is their top.
	local params = self._guideTopParams or RaycastParams.new()
	self._guideTopParams = params
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { guide }
	params.IgnoreWater = true
	params.RespectCanCollide = false
	local ray_length = box_size.Magnitude * 2 + 8
	local ray_origin = Vector3.new(
		sample_position and sample_position.X or box_cframe.Position.X,
		box_cframe.Position.Y + box_size.Magnitude + 4,
		sample_position and sample_position.Z or box_cframe.Position.Z
	)
	local sampled_top = Workspace:Raycast(
		ray_origin,
		Vector3.new(0, -ray_length, 0),
		params
	)
	if sampled_top and sampled_top.Normal.Y >= 0.5 then
		return {
			Instance = sampled_top.Instance,
			Guide = guide,
			Position = sampled_top.Position,
			Normal = sampled_top.Normal,
			BoxCFrame = box_cframe,
			BoxSize = box_size,
		}
	end

	-- Retain the oriented-box fallback for guides whose center is hollow or
	-- whose top cannot be sampled, but only when the box's own up axis is
	-- sufficiently walkable.
	local up = box_cframe.UpVector
	if up.Y < 0.5 then
		return nil
	end

	return {
		Instance = hit_instance,
		Guide = guide,
		Position = box_cframe.Position + up * (box_size.Y * 0.5),
		Normal = up,
		BoxCFrame = box_cframe,
		BoxSize = box_size,
	}
end

function ParkourController:_get_guide_tops(guide, sample_position)
	local first_top = self:_get_guide_top(guide, sample_position)
	if not first_top then return {} end

	local tops = { first_top }
	local params = self._guideTopParams or RaycastParams.new()
	self._guideTopParams = params
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { guide }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local sample_x = sample_position and sample_position.X or first_top.Position.X
	local sample_z = sample_position and sample_position.Z or first_top.Position.Z
	local ray_length = first_top.BoxSize.Magnitude * 2 + 8
	local ray_origin = Vector3.new(sample_x, first_top.Position.Y - 0.05, sample_z)
	local previous_y = first_top.Position.Y

	-- Starting just below each found surface exposes the next lower part in a
	-- stacked Model without globally ray-filtering out the whole tagged guide.
	for _ = 2, Config.MaxTopSurfaceHits do
		local hit = Workspace:Raycast(
			ray_origin,
			Vector3.new(0, -ray_length, 0),
			params
		)
		if not hit then break end
		if hit.Normal.Y >= 0.5 and previous_y - hit.Position.Y >= 0.25 then
			table.insert(tops, {
				Instance = hit.Instance,
				Guide = guide,
				Position = hit.Position,
				Normal = hit.Normal,
				BoxCFrame = first_top.BoxCFrame,
				BoxSize = first_top.BoxSize,
			})
		end
		previous_y = hit.Position.Y
		ray_origin = Vector3.new(sample_x, hit.Position.Y - 0.05, sample_z)
	end

	return tops
end

function ParkourController:_try_ground_mantle(current_top, normal, tangent)
	local root = self.Root
	if not root or not current_top or not normal or not tangent then
		return false
	end

	local outward_normal = flatten(normal)
	local sideways = flatten(tangent)
	if outward_normal.Magnitude < 0.05 or sideways.Magnitude < 0.05 then
		return false
	end
	outward_normal = outward_normal.Unit
	sideways = sideways.Unit

	local standing_height = self:_standing_height()
	local lateral_step = math.max(root.Size.X * 0.45, 0.4)
	local inward_offsets = { 0.5, 1, 1.75, 2.75, 4, 5.5, 7 }
	local lateral_factors = { 0, -1, 1 }
	local ray_origin_y = current_top.Y + Config.GroundMantleMaxRise + standing_height + 2
	local ray_length = Config.GroundMantleMaxRise + standing_height + 4
	local best_ground = nil
	local best_score = math.huge

	-- W can finish onto ordinary visible floor as well as a tagged guide.
	-- Probe several nearby columns ahead of the wall; only a real collidable,
	-- walkable, non-Climbable surface above the current ledge is eligible.
	for _, inward_offset in ipairs(inward_offsets) do
		for _, lateral_factor in ipairs(lateral_factors) do
			local sample = current_top
				- outward_normal * inward_offset
				+ sideways * (lateral_step * lateral_factor)
			local ground = self:_cast(
				Vector3.new(sample.X, ray_origin_y, sample.Z),
				Vector3.new(0, -ray_length, 0),
				true
			)
			if ground and ground.Normal.Y >= 0.5 and not self:_is_climbable(ground.Instance) then
				local rise = ground.Position.Y - current_top.Y
				local relative = ground.Position - current_top
				local inward_distance = relative:Dot(-outward_normal)
				local lateral_distance = math.abs(flatten(relative):Dot(sideways))
				local root_to_floor = root.Position.Y - ground.Position.Y
				local reachable = rise > Config.MantleMinRise
					and rise <= Config.GroundMantleMaxRise
					and inward_distance >= 0.25
					and inward_distance <= Config.MantleMaxInward
					and lateral_distance <= Config.MantleMaxLateral
					and root_to_floor <= Config.GroundMantleMaxRise + Config.HangDrop

				if reachable then
					local score = inward_distance * inward_distance
						+ lateral_distance * lateral_distance
						+ rise * rise * 0.15
					if score < best_score then
						best_ground = ground
						best_score = score
					end
				end
			end
		end
	end

	if not best_ground then
				return false
	end

	local grounded_position = Vector3.new(
		best_ground.Position.X,
		best_ground.Position.Y + standing_height - 0.05,
		best_ground.Position.Z
	)
		self.GrabBlockedUntilJumpReleased = true
	if self.Humanoid then
		self.JumpingEnabledBeforeMantle = self.Humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		self.Humanoid.Jump = false
	end
	local start_cframe = root.CFrame
	local target_cframe = CFrame.lookAt(grounded_position, grounded_position - outward_normal)
	-- Keep the hang's movement lock while blending to the floor so the
	-- Humanoid cannot fight the scripted mantle path.
	self.State = "Mantling"
	self.CurrentClimbable = nil
	self.Normal = nil
	self.HangDepthOffset = nil
	self.HangPosition = nil
	self.CornerLockPosition = nil
	self.CornerLockInputDirection = nil
	self._mantleStart = start_cframe
	self._mantleTarget = target_cframe
	self._mantleElapsed = 0
	self._mantleDuration = 0.35
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

function ParkourController:_is_guide_within_mantle_search(guide, current_top, normal, tangent)
	local bounds_cframe
	local bounds_size

	if guide:IsA("BasePart") then
		bounds_cframe = guide.CFrame
		bounds_size = guide.Size
	elseif guide:IsA("Model") then
		bounds_cframe, bounds_size = guide:GetBoundingBox()
	else
		return false
	end

	-- The bounding sphere is a conservative broad-phase: it can admit extra
	-- guides, but cannot exclude a guide whose bounds intersect the mantle
	-- search volume. Detailed raycasts still decide whether a top is usable.
	local radius = bounds_size.Magnitude * 0.5
	local relative = flatten(bounds_cframe.Position - current_top)
	local inward = relative:Dot(-normal)
	local lateral = math.abs(relative:Dot(tangent))

	return inward + radius >= -Config.MantleMaxOutward
		and inward - radius <= Config.MantleMaxInward
		and lateral - radius <= Config.MantleMaxLateral
end

function ParkourController:_try_mantle()
		if self.State ~= "Hanging" or not self.Root or not self.CurrentClimbable
		or not self.HangPosition or not self.Normal
		or not self.CurrentClimbable:IsDescendantOf(Workspace) then
				return
	end

	local root = self.Root
	local normal = self.Normal
	local current_top = self.HangPosition
		- normal * Config.WallGap
		+ Vector3.new(0, Config.HangDrop, 0)
	local tangent = flatten(root.CFrame.RightVector)
	if tangent.Magnitude > 0.05 then
		tangent = tangent.Unit
	else
		tangent = flatten(Vector3.yAxis:Cross(normal)).Unit
	end

	local best_top = nil
	-- Prefer the nearest higher surface, not the center/top of the tagged
	-- Model. The model-wide bounding box can shift when an unrelated support
	-- part is resized, even though the authored ledge marker stays in place.
	local best_height = math.huge
	local best_distance = math.huge
	local considered = 0
	local rejected = 0
	local lateral_samples = { 0, -1.5, 1.5, -3, 3, -4.5, 4.5 }
	local inward_samples = { -1, 0.5, 1.5, 3, 5, 7 }

	local function consider_higher_top(guide, top)
		if not top or top.Normal.Y < 0.5 then return end
		local relative = top.Position - current_top
		local inward = relative:Dot(-normal)
		local lateral = math.abs(flatten(relative):Dot(tangent))
		local rise = top.Position.Y - current_top.Y
		local root_height_delta = root.Position.Y - top.Position.Y
		local in_vertical_range = rise > Config.MantleMinRise
			and rise <= Config.MantleMaxRise
			and root_height_delta >= -(Config.MantleMaxRise + Config.HangDrop)
			and root_height_delta <= Config.MaxGrabHeight
		local in_reach = inward >= -Config.MantleMaxOutward
			and inward <= Config.MantleMaxInward
			and lateral <= Config.MantleMaxLateral

		if in_vertical_range and in_reach then
			considered += 1
			local horizontal_distance = flatten(relative).Magnitude
			if rise < best_height
				or (math.abs(rise - best_height) < 1e-4 and horizontal_distance < best_distance) then
				best_top = top
				best_height = rise
				best_distance = horizontal_distance
							end
		else
			rejected += 1
					end
	end

	-- Sample real surface columns around the current hang point. This avoids
	-- using a resized parent Model's bounding-box center or footprint as the
	-- destination, while still finding offset, wide, and multi-part ledges.
	for _, guide in ipairs(CollectionService:GetTagged(Config.ClimbableTag)) do
		if guide:IsDescendantOf(Workspace) then
			for _, lateral_offset in ipairs(lateral_samples) do
				for _, inward_offset in ipairs(inward_samples) do
					local sample_position = current_top
						+ tangent * lateral_offset
						- normal * inward_offset
					-- Enumerate the exposed tops in this column. A broad backing
					-- part can be the first hit while a reachable ledge sits below it.
					for _, top in ipairs(self:_get_guide_tops(guide, sample_position)) do
						consider_higher_top(guide, top)
					end
				end
			end
		end
	end

	if best_top then
				-- Resolve the destination ledge's exposed vertical face as well as
		-- its top. A higher ledge can face a different direction from the wall
		-- we're leaving, so keep its own outward normal and depth offset.
		local target_normal = self:_get_ledge_outward_normal(best_top, root.Position)
		if target_normal then
						self:_transfer_hang_to_ledge(best_top, target_normal)
		else
						self:_transfer_hang_to_ledge(best_top)
		end
	else
		-- No higher tagged guide was found. W may still mantle onto visible
		-- ordinary ground above the current wall.
		if not self:_try_ground_mantle(current_top, normal, tangent) then
					end
	end
end

function ParkourController:_release()
	if self._topHopActive then
		self:_finish_top_hop(false)
	end
	if self.State == "Vaulting" then
		self:_finish_vault(false)
		return
	end
	if self.State ~= "Hanging" then
				return
	end
		self.State = "Grounded"
	self.CurrentClimbable = nil
	self.Normal = nil
	self.HangDepthOffset = nil
	self.HangPosition = nil
	self.CornerLockPosition = nil
	self.CornerLockInputDirection = nil

	local humanoid = self.Humanoid
	if humanoid then
		if self.AutoRotateBeforeHang ~= nil then
			humanoid.AutoRotate = self.AutoRotateBeforeHang
		end
		if self.PlatformStandBeforeHang ~= nil then
			humanoid.PlatformStand = self.PlatformStandBeforeHang
		end
	end
	self.AutoRotateBeforeHang = nil
	self.PlatformStandBeforeHang = nil
	if self.MovementController then
		self.MovementController:SetSprintBlocked(false, self)
	end
end

function ParkourController:Destroy()
	self:_release()
	if self.HangClearanceProbe then
		self.HangClearanceProbe:Destroy()
		self.HangClearanceProbe = nil
	end
	self.Trove:Destroy()
end

return ParkourController
