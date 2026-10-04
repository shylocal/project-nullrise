local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(ReplicatedStorage.shared.config).Parkour
local LedgeDetection = require(script.Parent.LedgeDetection)

local State = require(script.Parent.State)
local Metrics = require(script.Parent.Metrics)
local Queries = require(script.Parent.Queries)
local Traversal = require(script.Parent.Traversal)
local VaultMath = require(script.Parent.VaultMath)

local LedgeTraversal = {}

local function try_lower_ledge_impl(self)
	local hang = State.hang(self)
	if not hang or not self.Root then
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
	local hang = State.hang(self)
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
	local actual_guide = self.Climbables:GuideOf(top.Instance) or top.Instance
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
	local hang = State.hang(self)
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
	local target_guide = top.Guide or self.Climbables:GuideOf(top.Instance) or top.Instance

	local planned_position = top.Position
		+ depth_offset
		- Vector3.new(0, Config.HangDrop, 0)
	local planned_clear = Queries.has_hang_body_clearance(self, 
		planned_position,
		destination_normal
	)
	if not planned_clear then
		return false
	end

	local pose_snapshot = Traversal.snapshot_hang_pose(self)
	hang = {
		CurrentClimbable = target_guide,
		Normal = destination_normal,
		HangDepthOffset = depth_offset,
		HangPosition = top.Position + depth_offset - Vector3.new(0, Config.HangDrop, 0),
		CornerLockPosition = nil,
		CornerLockInputDirection = nil,
	}
	if not State.enter(self, { kind = "Hanging", data = hang }) then
		return false
	end
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
	local final_clear = Queries.has_hang_body_clearance(self, 
		hang.HangPosition,
		hang.Normal
	)
	if not final_clear then
		Traversal.restore_hang_pose(self, pose_snapshot)
		return false
	end
	-- An input-driven snap: no frame time has elapsed.
	self:_position_hanging(0)
	return true
end

-- Leaves the hang for a scripted mantle to `target_cframe`. Entering Mantling
-- keeps the hang's body pose until the mantle ends and disables native
-- jumping until Space is released.
local function begin_mantle(self, root, target_cframe)
	if not State.enter(self, {
		kind = "Mantling",
		data = {
			Start = root.CFrame,
			Target = target_cframe,
			Elapsed = 0,
			Duration = Config.MantleDuration,
		},
	}) then
		return false
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end
function LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
	local hang = State.hang(self)
	local root = self.Root
	if not hang or not root or not current_top or not normal or not tangent then
		return false
	end

	local standing_height = self:_standing_height()
	local ground = LedgeDetection.find_ground_mantle(
		self,
		current_top,
		normal,
		tangent,
		hang.CurrentClimbable,
		root.Position.Y,
		standing_height,
		root.Size.X
	)
	if not ground then
		return false
	end

	local grounded_position = Vector3.new(
		ground.Position.X,
		ground.Position.Y + standing_height - 0.05,
		ground.Position.Z
	)
	local target_cframe = CFrame.lookAt(grounded_position, grounded_position - Vector.flatten(normal).Unit)
	return begin_mantle(self, root, target_cframe)
end
function LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
	local hang = State.hang(self)
	if not hang then
		return false
	end
	local root = self.Root
	local wall = hang.CurrentClimbable
	if not root or not wall or not wall:IsA("BasePart")
		or not wall.CanCollide or self.Climbables:IsClimbable(wall) then
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

	local target_cframe = CFrame.lookAt(standing_position, standing_position - normal)
	return begin_mantle(self, root, target_cframe)
end

local function try_mantle_impl(self)
	local hang = State.hang(self)
	if not hang or not self.Root
		or not hang.CurrentClimbable:IsDescendantOf(Workspace) then
		return
	end

	local root = self.Root
	local normal = hang.Normal
	local is_tagged_guide = self.Climbables:IsClimbable(hang.CurrentClimbable)
	local depth_offset = if is_tagged_guide
		then normal * Config.WallGap
		else (hang.HangDepthOffset or normal * Config.WallGap)
	local current_top = hang.HangPosition
		- depth_offset
		+ Vector3.new(0, Config.HangDrop, 0)

	if not is_tagged_guide then
		LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
		return
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

	local best_top = LedgeDetection.find_higher_ledge(self, current_top, normal, tangent, root.Position.Y)
	if best_top then
		local target_normal = LedgeDetection.get_ledge_outward_normal(self, best_top, root.Position)
		LedgeTraversal.transfer_hang_to_ledge(self, best_top, target_normal)
		return
	end

	LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
end

-- Advances an active mantle. Returns false when there is no valid mantle to
-- advance (the caller releases).
function LedgeTraversal.update_mantle(self, dt)
	local root = self.Root
	local mantle = State.mantle(self)
	if not mantle or mantle.Duration <= 0 then
		return false
	end

	mantle.Elapsed = math.min(mantle.Elapsed + math.max(dt, 0), mantle.Duration)
	local linear = mantle.Elapsed / mantle.Duration
	local alpha = VaultMath.smoothstep(linear)
	if root then
		root.CFrame = mantle.Start:Lerp(mantle.Target, alpha)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	if linear >= 1 then
		-- Leaving Mantling restores the hang body pose and releases the
		-- Mantle lease; the disabled jump stays with the Jump latch.
		State.enter(self, { kind = "Grounded" })
		if self.Humanoid then
			self.Humanoid:ChangeState(Enum.HumanoidStateType.Running)
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
