local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)

local ClimbableQuery = require(script.Parent.ClimbableQuery)

local LedgeTraversal = {}

local function debug_log(self, key, interval, ...)
	local now = os.clock()
	self._parkourDebugTimes = self._parkourDebugTimes or {}
	if now - (self._parkourDebugTimes[key] or 0) < interval then return end
	self._parkourDebugTimes[key] = now
	print("[ParkourDebug][" .. key .. "]", ...)
end

function LedgeTraversal.try_lower_ledge(self)
		if self.State ~= "Hanging" or not self.Root or not self.CurrentClimbable
		or not self.HangPosition or not self.Normal then
				return
	end

	local root = self.Root
	debug_log(self, "lower-ledge", 0, "begin", "surface", self.CurrentClimbable:GetFullName(),
		"hangPosition", self.HangPosition, "root", root.Position)
	local normal = Vector.flatten(self.Normal)
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
		local lateral_gap = math.abs(Vector.flatten(relative):Dot(tangent))
		local in_vertical_range = drop >= 0.5 and drop <= Config.MantleMaxRise
		local in_reach = inward >= -Config.MantleMaxOutward
			and inward <= Config.MantleMaxInward
			and lateral_gap <= Config.MantleMaxLateral

		if in_vertical_range and in_reach then
			local target_top_position = top.Position
			local horizontal_distance = Vector.flatten(target_top_position - current_top).Magnitude
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
		debug_log(self, "lower-ledge", 0, "no lower tagged ledge found",
			"source", self.CurrentClimbable:GetFullName(), "currentTop", current_top)
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
	local transferred = self:_transfer_hang_to_ledge(best_top, target_normal)
	debug_log(self, "lower-ledge", 0, "transfer result", transferred,
		"destination", best_top.Instance:GetFullName(), "targetNormal", target_normal)
end
function LedgeTraversal.refresh_hang_contact(self, expected_guide, expected_top_y)
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
	local probe = self:_cast_grabbable_side(
		probe_origin,
		-normal * (Config.WallGap + Config.SurfaceProbe)
	)
	if not probe then
		debug_log(self, "refresh-contact", 0, "no side hit", "expected", expected_guide:GetFullName(),
			"origin", probe_origin, "direction", -normal * (Config.WallGap + Config.SurfaceProbe))
		return false
	end

	local top = self:_cast_reachable_grab_top(
		probe.Position,
		probe.Normal,
		candidate_position,
		candidate_position.Y + Config.HangDrop,
		nil,
		probe.Instance
	)
	if not top then
		debug_log(self, "refresh-contact", 0, "no reachable top", "expected", expected_guide:GetFullName(),
			"sideHit", probe.Instance:GetFullName(), "sideNormal", probe.Normal)
		return false
	end
	local actual_guide = ClimbableQuery.get_guide(top.Instance) or top.Instance
	if actual_guide ~= expected_guide then
		debug_log(self, "refresh-contact", 0, "guide mismatch", "expected", expected_guide:GetFullName(),
			"actual", actual_guide:GetFullName(), "top", top.Instance:GetFullName())
		return false
	end
	if expected_top_y and math.abs(top.Position.Y - expected_top_y) > Config.TraverseHeightTolerance then
		debug_log(self, "refresh-contact", 0, "height mismatch", "expectedY", expected_top_y,
			"actualY", top.Position.Y, "tolerance", Config.TraverseHeightTolerance)
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
	self.Normal = horizontal_normal
	self.HangDepthOffset = horizontal_normal * Config.WallGap
	self.HangPosition = Vector3.new(
		top.Position.X,
		candidate_position.Y,
		top.Position.Z
	) + self.HangDepthOffset
	return true
end
function LedgeTraversal.get_ledge_outward_normal(self, top, reference_position)
	if not top or not top.Instance or not top.Instance:IsA("BasePart") then
		return nil
	end

	local part = top.Instance
	local guide = top.Guide or ClimbableQuery.get_guide(part) or part

	-- The top surface normal is vertical and cannot tell us which vertical
	-- face the destination ledge presents. Probe outward from the actual
	-- sampled part along its local horizontal face axes and world axes; the
	-- raycast's side normal identifies the face that is exposed to the player.
	local axes = {}
	local function add_axis(axis)
		local horizontal = Vector.flatten(axis)
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
		local hit = self:_cast_grabbable_side(origin, -outward * probe_length)
		if hit and (ClimbableQuery.get_guide(hit.Instance) or hit.Instance) == guide then
			local face_normal = Vector.flatten(hit.Normal)
			if face_normal.Magnitude >= 0.05 then
				face_normal = face_normal.Unit
				local face_alignment = face_normal:Dot(outward)
				if face_alignment >= 0.5 then
					local toward_player = Vector.flatten(reference_position - hit.Position)
					local player_alignment = 0
					if toward_player.Magnitude >= 0.05 then
						player_alignment = math.max(0, face_normal:Dot(toward_player.Unit))
					end
					local distance = Vector.flatten(reference_position - hit.Position).Magnitude
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
function LedgeTraversal.transfer_hang_to_ledge(self, top, target_normal)
	local root = self.Root
	local normal = self.Normal
	if not root or not top or not normal then return false end

	local destination_normal = Vector.flatten(target_normal or normal)
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
	elseif not depth_offset or Vector.flatten(depth_offset).Magnitude < 0.05 then
		depth_offset = destination_normal * Config.WallGap
	end
	local target_guide = top.Guide or ClimbableQuery.get_guide(top.Instance) or top.Instance

	local planned_position = top.Position
		+ depth_offset
		- Vector3.new(0, Config.HangDrop, 0)
	local planned_clear, planned_blocker = self:_has_hang_body_clearance(
		planned_position,
		destination_normal
	)
	if not planned_clear then
		debug_log(self, "transfer", 0, "planned clearance rejected", "destination", target_guide:GetFullName(),
			"blocker", planned_blocker and planned_blocker:GetFullName(), "position", planned_position,
			"normal", destination_normal)
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
		debug_log(self, "transfer", 0, "refresh contact rejected", "destination", target_guide:GetFullName(),
			"top", top.Instance:GetFullName(), "topPosition", top.Position)
		self:_restore_hang_pose(pose_snapshot)
		return false
	end
		local final_clear, final_blocker = self:_has_hang_body_clearance(
		self.HangPosition,
		self.Normal
	)
	if not final_clear then
		debug_log(self, "transfer", 0, "final clearance rejected", "destination", target_guide:GetFullName(),
			"blocker", final_blocker and final_blocker:GetFullName(), "position", self.HangPosition,
			"normal", self.Normal)
		self:_restore_hang_pose(pose_snapshot)
		return false
	end
	self:_position_hanging()
	debug_log(self, "transfer", 0, "accepted", "destination", target_guide:GetFullName(),
		"position", self.HangPosition, "normal", self.Normal)
	return true
end
function LedgeTraversal.get_guide_top(self, guide, sample_position)
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
function LedgeTraversal.get_guide_tops(self, guide, sample_position)
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
local function cast_mantle_ground(self, origin, direction)
	local params = self._mantleGroundParams or RaycastParams.new()
	self._mantleGroundParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local exclusions = { self.Character }
	for _ = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local hit = Workspace:Raycast(origin, direction, params)
		if not hit then
			return nil
		end

		local is_climbable_group = hit.Instance:IsA("BasePart")
			and hit.Instance.CollisionGroup == Config.ClimbableCollisionGroup
		if not is_climbable_group then
			return hit
		end

		-- Climbable collision-group parts are query helpers/proxies, not mantle
		-- destinations. Skip them and continue looking for the real surface.
		table.insert(exclusions, hit.Instance)
	end

	return nil
end

function LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
	local root = self.Root
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
				local is_current_surface = ground.Instance == self.CurrentClimbable
					or (ground_guide ~= nil and ground_guide == self.CurrentClimbable)
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
function LedgeTraversal.is_guide_within_mantle_search(self, guide, current_top, normal, tangent)
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
	local relative = Vector.flatten(bounds_cframe.Position - current_top)
	local inward = relative:Dot(-normal)
	local lateral = math.abs(relative:Dot(tangent))

	return inward + radius >= -Config.MantleMaxOutward
		and inward - radius <= Config.MantleMaxInward
		and lateral - radius <= Config.MantleMaxLateral
end
function LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
	local root = self.Root
	local wall = self.CurrentClimbable
	if not root or not wall or not wall:IsA("BasePart")
		or not wall.CanCollide or ClimbableQuery.is_climbable(wall) then
		return false
	end

	-- The generic-wall grab is anchored to this exact solid part. Mantle onto
	-- its own top, inset only by the root's depth plus a small safety margin.
	local top = self:_get_guide_top(wall, current_top)
	if not top or top.Instance ~= wall or top.Normal.Y < 0.5 then
		return false
	end
	local support = self:_cast(
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
	local clear = self:_has_hang_body_clearance(standing_position, normal)
	if not clear then
		return false
	end

	self.GrabBlockedUntilJumpReleased = true
	if self.Humanoid then
		self.JumpingEnabledBeforeMantle = self.Humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
		self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		self.Humanoid.Jump = false
	end

	local target_cframe = CFrame.lookAt(standing_position, standing_position - normal)
	self.State = "Mantling"
	self.CurrentClimbable = nil
	self.Normal = nil
	self.HangDepthOffset = nil
	self.HangPosition = nil
	self.CornerLockPosition = nil
	self.CornerLockInputDirection = nil
	self._mantleStart = root.CFrame
	self._mantleTarget = target_cframe
	self._mantleElapsed = 0
	self._mantleDuration = 0.35
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

function LedgeTraversal.try_mantle(self)
		if self.State ~= "Hanging" or not self.Root or not self.CurrentClimbable
		or not self.HangPosition or not self.Normal
		or not self.CurrentClimbable:IsDescendantOf(Workspace) then
				return
	end

	local root = self.Root
	local normal = self.Normal
	local is_tagged_guide = ClimbableQuery.is_climbable(self.CurrentClimbable)
	local depth_offset = if is_tagged_guide
		then normal * Config.WallGap
		else (self.HangDepthOffset or normal * Config.WallGap)
	local current_top = self.HangPosition
		- depth_offset
		+ Vector3.new(0, Config.HangDrop, 0)
	if not is_tagged_guide then
		return LedgeTraversal.try_tall_wall_mantle(self, current_top, normal)
	end
	local tangent = Vector.flatten(root.CFrame.RightVector)
	if tangent.Magnitude > 0.05 then
		tangent = tangent.Unit
	else
		tangent = Vector.flatten(Vector3.yAxis:Cross(normal)).Unit
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
		if top.Instance:IsA("BasePart")
			and top.Instance.CollisionGroup == Config.ClimbableCollisionGroup
			and not ClimbableQuery.is_climbable(top.Instance) then
			return
		end
		local relative = top.Position - current_top
		local inward = relative:Dot(-normal)
		local lateral = math.abs(Vector.flatten(relative):Dot(tangent))
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
			local horizontal_distance = Vector.flatten(relative).Magnitude
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

	-- Sample tagged guides for multi-part ledges, while the ground fallback below
	-- handles ordinary untagged parts.
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
		local transferred
		if target_normal then
			transferred = self:_transfer_hang_to_ledge(best_top, target_normal)
		else
			transferred = self:_transfer_hang_to_ledge(best_top)
		end
		debug_log(self, "mantle", 0, "tagged destination", best_top.Instance:GetFullName(),
			"rise", best_height, "distance", best_distance, "transfer", transferred)
	else
		-- No higher tagged guide was found. W may still mantle onto any visible,
		-- walkable surface above the current wall.
		local ground_mantled = self:_try_ground_mantle(current_top, normal, tangent)
		debug_log(self, "mantle", 0, "no tagged destination; ground mantle result", ground_mantled,
			"source", self.CurrentClimbable and self.CurrentClimbable:GetFullName(),
			"currentTop", current_top, "maxRise", Config.GroundMantleMaxRise)
	end
end

return LedgeTraversal
