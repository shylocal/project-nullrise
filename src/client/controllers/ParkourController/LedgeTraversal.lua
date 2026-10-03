local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)
local LedgeDetection = require(script.Parent.LedgeDetection)

local ClimbableQuery = require(script.Parent.ClimbableQuery)
local ParkourState = require(script.Parent.State)
local Metrics = require(script.Parent.Metrics)
local Queries = require(script.Parent.Queries)
local Traversal = require(script.Parent.Traversal)
local VaultMath = require(script.Parent.VaultMath)

local LedgeTraversal = {}

local function try_lower_ledge_impl(self)
	local hang = ParkourState.get_data(self, "Hanging")
	if self.State ~= "Hanging" or not self.Root or not hang.CurrentClimbable
		or not hang.HangPosition or not hang.Normal then
		return
	end

	local root = self.Root
	local normal = Vector.flatten(hang.Normal)
	if normal.Magnitude < 0.05 then
		return
	end
	normal = normal.Unit

	local tangent = Vector.flatten(root.CFrame.RightVector)
	if tangent.Magnitude < 0.05 then
		tangent = Vector.flatten(Vector3.yAxis:Cross(normal))
	end
	if tangent.Magnitude < 0.05 then
		return
	end
	tangent = tangent.Unit

	local current_top = hang.HangPosition - normal * Config.WallGap + Vector3.new(0, Config.HangDrop, 0)
	local best_top = LedgeDetection.find_lower_ledge(self, current_top, normal, tangent)
	if not best_top then
		return
	end

	local target_normal = LedgeDetection.get_ledge_outward_normal(self, best_top, root.Position) or normal
	LedgeTraversal.transfer_hang_to_ledge(self, best_top, target_normal)
end
function LedgeTraversal.refresh_hang_contact(self, expected_guide, expected_top_y)
	local hang = ParkourState.get_data(self, "Hanging")
	local root = self.Root
	local normal = hang and hang.Normal
	local candidate_position = root and hang.HangPosition
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
	local probe = Queries.cast(self, 
		probe_origin,
		-normal * (Config.WallGap + Config.SurfaceProbe)
	)
	if not probe then
		return false
	end

	local top = Queries.cast_reachable_grab_top(self, 
		probe.Position,
		probe.Normal,
		candidate_position,
		candidate_position.Y + Config.HangDrop
	)
	if not top then
		return false
	end
	local actual_guide = ClimbableQuery.get_guide(top.Instance) or top.Instance
	if actual_guide ~= expected_guide then
		return false
	end
	if expected_top_y and math.abs(top.Position.Y - expected_top_y) > Config.TraverseHeightTolerance then
		return false
	end

	local horizontal_normal = Vector.flatten(probe.Normal)
	if horizontal_normal.Magnitude < 0.05 then
		return false
	end
	horizontal_normal = horizontal_normal.Unit

	-- Match the successful A/D contact correction exactly: anchor X/Z to the
	-- locally sampled top/wall, retain the selected hang height, and face the
	-- actual wall normal. This runs synchronously within W/S, so no sideways
	-- input is needed to settle the character.
	hang.Normal = horizontal_normal
	hang.HangDepthOffset = horizontal_normal * Config.WallGap
	hang.HangPosition = Vector3.new(
		top.Position.X,
		candidate_position.Y,
		top.Position.Z
	) + hang.HangDepthOffset
	return true
end
function LedgeTraversal.transfer_hang_to_ledge(self, top, target_normal)
	local hang = ParkourState.get_data(self, "Hanging")
	local root = self.Root
	local normal = hang and hang.Normal
	if not root or not top or not normal then return false end

	local destination_normal = Vector.flatten(target_normal or normal)
	if destination_normal.Magnitude < 0.05 then return false end
	destination_normal = destination_normal.Unit

	-- W/S change ledge height. Begin with the cached hang transform, then
	-- immediately resolve the destination's actual side/top contact using the
	-- same probe that has been correcting the position during A/D traversal.
	local depth_offset = hang.HangDepthOffset
	if target_normal then
		-- A vertical transfer may land on a ledge whose wall faces another
		-- direction. Use its detected destination normal for both facing and
		-- stand-off depth instead of carrying the source wall's cached offset.
		depth_offset = destination_normal * Config.WallGap
	elseif not depth_offset or Vector.flatten(depth_offset).Magnitude < 0.05 then
		depth_offset = destination_normal * Config.WallGap
	end
	local target_guide = top.Guide or ClimbableQuery.get_guide(top.Instance) or top.Instance

	local planned_position = top.Position
		+ depth_offset
		- Vector3.new(0, Config.HangDrop, 0)
	local planned_clear, planned_blocker = Queries.has_hang_body_clearance(self, 
		planned_position,
		destination_normal
	)
	if not planned_clear then
		return false
	end

	local pose_snapshot = Traversal.snapshot_hang_pose(self)
	if not ParkourState.transition(self, "Hanging") then
		return false
	end
	hang = ParkourState.set_data(self, "Hanging", {
		CurrentClimbable = target_guide,
		Normal = destination_normal,
		HangDepthOffset = depth_offset,
		HangPosition = top.Position + depth_offset - Vector3.new(0, Config.HangDrop, 0),
		CornerLockPosition = nil,
		CornerLockInputDirection = nil,
	})
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	-- Resolve the destination wall contact before moving the character. The
	-- sampled top can be laterally offset from the actual wall face; placing
	-- the root at this provisional pose first causes a visible/physical nudge
	-- into the ledge during simultaneous sideways and vertical input.
	local refreshed = LedgeTraversal.refresh_hang_contact(self, target_guide, top.Position.Y)
	if not refreshed then
		Traversal.restore_hang_pose(self, pose_snapshot)
		return false
	end
		local final_clear, final_blocker = Queries.has_hang_body_clearance(self, 
		hang.HangPosition,
		hang.Normal
	)
	if not final_clear then
		Traversal.restore_hang_pose(self, pose_snapshot)
		return false
	end
	self:_position_hanging()
	return true
end
function LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
	local hang = ParkourState.get_data(self, "Hanging")
	local root = self.Root
	if not hang or not root or not current_top or not normal or not tangent then
		return false
	end

	local ground = LedgeDetection.find_ground_mantle(
		self,
		current_top,
		normal,
		tangent,
		hang.CurrentClimbable
	)
	if not ground then
		return false
	end

	local standing_height = self:_standing_height()
	local grounded_position = Vector3.new(
		ground.Position.X,
		ground.Position.Y + standing_height - 0.05,
		ground.Position.Z
	)
	if not ParkourState.transition(self, "Mantling") then
		return false
	end
	self.GrabBlockedUntilJumpReleased = true
	if self.Humanoid then
		ParkourState.capture_humanoid(self, "Mantle", { "JumpingEnabled" })
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		self.Humanoid.Jump = false
	end
	local start_cframe = root.CFrame
	local target_cframe = CFrame.lookAt(grounded_position, grounded_position - Vector.flatten(normal).Unit)
	ParkourState.clear_data(self, "Hanging")
	ParkourState.set_data(self, "Mantling", {
		Start = start_cframe,
		Target = target_cframe,
		Elapsed = 0,
		Duration = 0.35,
	})
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end
function LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
	local hang = ParkourState.get_data(self, "Hanging")
	local root = self.Root
	if not hang then
		return false
	end
	if not root or not current_top or not normal or not tangent then
		return false
	end

	local outward_normal = Vector.flatten(normal)
	local sideways = Vector.flatten(tangent)
	if outward_normal.Magnitude < 0.05 or sideways.Magnitude < 0.05 then
		return false
	end
	outward_normal = outward_normal.Unit
	sideways = sideways.Unit

	local standing_height = self:_standing_height()
	local max_rise = Config.GroundMantleMaxRise
	local lateral_step = math.max(root.Size.X * 0.45, 0.4)
	local inward_offsets = { 0.5, 1, 1.75, 2.75, 4, 5.5, 7 }
	local lateral_factors = { 0, -1, 1 }
	local ray_origin_y = current_top.Y + max_rise + standing_height + 2
	local ray_length = max_rise + standing_height + 4
	local best_ground = nil
	local best_score = math.huge

	-- W can mantle onto any collidable, walkable surface, including untagged
	-- parts. The Climbable collision group is reserved for query/helper geometry.
	for _, inward_offset in ipairs(inward_offsets) do
		for _, lateral_factor in ipairs(lateral_factors) do
			local sample = current_top
				- outward_normal * inward_offset
				+ sideways * (lateral_step * lateral_factor)
			local ground = cast_mantle_ground(
				self,
				Vector3.new(sample.X, ray_origin_y, sample.Z),
				Vector3.new(0, -ray_length, 0)
			)
			if ground and ground.Normal.Y >= 0.5 then
				local ground_guide = ClimbableQuery.get_guide(ground.Instance)
				local is_current_surface = ground.Instance == hang.CurrentClimbable
					or (ground_guide ~= nil and ground_guide == hang.CurrentClimbable)
				local rise = ground.Position.Y - current_top.Y
				local relative = ground.Position - current_top
				local inward_distance = relative:Dot(-outward_normal)
				local lateral_distance = math.abs(Vector.flatten(relative):Dot(sideways))
				local root_to_floor = root.Position.Y - ground.Position.Y
				-- The current ledge may be level with the hang point; other
				-- surfaces must still rise enough to be a meaningful mantle.
				local minimum_rise = if is_current_surface then -0.25 else Config.MantleMinRise
				local reachable = rise >= minimum_rise
					and rise <= max_rise
					and inward_distance >= 0.25
					and inward_distance <= Config.MantleMaxInward
					and lateral_distance <= Config.MantleMaxLateral
					and root_to_floor <= max_rise + Config.HangDrop

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
		if not ParkourState.transition(self, "Mantling") then
		return false
	end
	self.GrabBlockedUntilJumpReleased = true
	if self.Humanoid then
		ParkourState.capture_humanoid(self, "Mantle", { "JumpingEnabled" })
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		self.Humanoid.Jump = false
	end
	local start_cframe = root.CFrame
	local target_cframe = CFrame.lookAt(grounded_position, grounded_position - outward_normal)
	-- Keep the hang's movement lock while blending to the floor so the
	-- Humanoid cannot fight the scripted mantle path.
	ParkourState.clear_data(self, "Hanging")
	ParkourState.set_data(self, "Mantling", {
		Start = start_cframe,
		Target = target_cframe,
		Elapsed = 0,
		Duration = 0.35,
	})
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end
function LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
	local hang = ParkourState.get_data(self, "Hanging")
	if not hang then
		return false
	end
	local root = self.Root
	local wall = hang.CurrentClimbable
	if not root or not wall or not wall:IsA("BasePart")
		or not wall.CanCollide or ClimbableQuery.is_climbable(wall) then
		return false
	end

	-- The generic-wall grab is anchored to this exact solid part. Mantle onto
	-- its own top, inset only by the root's depth plus a small safety margin.
	local top = Queries.get_guide_top(self, wall, current_top)
	if not top or top.Instance ~= wall or top.Normal.Y < 0.5 then
		return false
	end
	local support = Queries.cast(self, 
		top.Position + Vector3.new(0, 1, 0),
		Vector3.new(0, -2, 0),
		true
	)
	if not support or support.Instance ~= wall or support.Normal.Y < 0.5 then
		return false
	end

	-- The top sample is 0.1 studs inside the lip; compensate so the
	-- root keeps only the configured clearance from the physical outer edge.
	local edge_inset = math.max(0, root.Size.Z * 0.5 + Config.TallWallEdgeClearance - 0.1)
	local standing_position = support.Position
		- normal * edge_inset
		+ Vector3.new(0, self:_standing_height() - 0.05, 0)
	local clear = Queries.has_hang_body_clearance(self, standing_position, normal)
	if not clear then
		return false
	end

	if not ParkourState.transition(self, "Mantling") then
		return false
	end
	self.GrabBlockedUntilJumpReleased = true
	if self.Humanoid then
		ParkourState.capture_humanoid(self, "Mantle", { "JumpingEnabled" })
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		self.Humanoid.Jump = false
	end

	local target_cframe = CFrame.lookAt(standing_position, standing_position - normal)
	ParkourState.clear_data(self, "Hanging")
	local mantle = ParkourState.set_data(self, "Mantling", {
		Start = root.CFrame,
		Target = target_cframe,
		Elapsed = 0,
		Duration = 0.35,
	})
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

local function try_mantle_impl(self)
	local hang = ParkourState.get_data(self, "Hanging")
	if self.State ~= "Hanging" or not self.Root or not hang.CurrentClimbable
		or not hang.HangPosition or not hang.Normal
		or not hang.CurrentClimbable:IsDescendantOf(Workspace) then
		return
	end

	local root = self.Root
	local normal = hang.Normal
	local is_tagged_guide = ClimbableQuery.is_climbable(hang.CurrentClimbable)
	local depth_offset = if is_tagged_guide
		then normal * Config.WallGap
		else (hang.HangDepthOffset or normal * Config.WallGap)
	local current_top = hang.HangPosition
		- depth_offset
		+ Vector3.new(0, Config.HangDrop, 0)

	if not is_tagged_guide then
		return LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
	end

	local tangent = Vector.flatten(root.CFrame.RightVector)
	if tangent.Magnitude > 0.05 then
		tangent = tangent.Unit
	else
		tangent = Vector.flatten(Vector3.yAxis:Cross(normal))
		if tangent.Magnitude < 0.05 then
			return
		end
		tangent = tangent.Unit
	end

	local best_top = LedgeDetection.find_higher_ledge(self, current_top, normal, tangent)
	if best_top then
		local target_normal = LedgeDetection.get_ledge_outward_normal(self, best_top, root.Position)
		LedgeTraversal.transfer_hang_to_ledge(self, best_top, target_normal)
		return
	end

	LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
end

function LedgeTraversal.update_mantle(self, dt)
	if self.State ~= "Mantling" then
		return false
	end

	local root = self.Root
	local mantle = ParkourState.get_data(self, "Mantling")
	local duration = mantle and mantle.Duration
	if not duration or duration <= 0 or not mantle.Start or not mantle.Target then
		return false
	end

	mantle.Elapsed = math.min((mantle.Elapsed or 0) + math.max(dt, 0), duration)
	local linear = mantle.Elapsed / duration
	local alpha = VaultMath.smoothstep(linear)
	if root then
		root.CFrame = mantle.Start:Lerp(mantle.Target, alpha)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if linear >= 1 then
		ParkourState.transition(self, "Grounded")
		ParkourState.clear_data(self, "Mantling")
		ParkourState.restore_humanoid(self, "Hang", { "AutoRotate", "PlatformStand" })
		if self.Humanoid then
			self.Humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
		if self.MovementController then
			self.MovementController:SetSprintBlocked(false, self)
		end
	end
	return true
end

function LedgeTraversal.try_lower_ledge(self)
	return Metrics.measure_search(self, "LowerLedge", try_lower_ledge_impl)
end

function LedgeTraversal.try_mantle(self)
	return Metrics.measure_search(self, "Mantle", try_mantle_impl)
end

return LedgeTraversal
