local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)
local ClimbableQuery = require(script.Parent.ClimbableQuery)

local Queries = {}

local function debug_log(self, key, interval, ...)
	local now = os.clock()
	self._parkourDebugTimes = self._parkourDebugTimes or {}
	if now - (self._parkourDebugTimes[key] or 0) < interval then return end
	self._parkourDebugTimes[key] = now
	print("[ParkourDebug][" .. key .. "]", ...)
end

function Queries.cast(self, origin, direction, respect_can_collide)
	local params = self._castParams or RaycastParams.new()
	self._castParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = respect_can_collide == true
	return Workspace:Raycast(origin, direction, params)
end
local function is_grabbable_surface(instance)
	if not instance:IsA("BasePart") then
		return false
	end

	-- Explicitly tagged climb guides are authored as invisible, non-collidable
	-- query volumes. Keep those eligible while continuing to ignore unrelated
	-- non-collidable parts and the helper collision group.
	local is_guide = ClimbableQuery.is_climbable(instance)
	if not is_guide
		and (not instance.CanCollide
			or instance.CollisionGroup == Config.ClimbableCollisionGroup) then
		return false
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	return not (model and model:FindFirstChildOfClass("Humanoid"))
end

function Queries.cast_grabbable_side(self, origin, direction)
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

		if is_grabbable_surface(hit.Instance) then
			return hit
		end

		-- Ignore climbable proxy geometry and decorative non-collidable parts.
		-- Other solid parts are valid grab surfaces only when they passed the
		-- grabbable-surface check above.
		if hit.Instance:IsA("BasePart")
			and (not hit.Instance.CanCollide
				or hit.Instance.CollisionGroup == Config.ClimbableCollisionGroup) then
			debug_log(self, "side-skip", 0.8, "part", hit.Instance:GetFullName(),
				"group", hit.Instance.CollisionGroup, "canCollide", hit.Instance.CanCollide,
				"tagged", ClimbableQuery.is_climbable(hit.Instance), "origin", origin, "direction", direction)
			table.insert(exclusions, hit.Instance)
		else
			debug_log(self, "side-block", 0.8, "part", hit.Instance:GetFullName(),
				"group", hit.Instance:IsA("BasePart") and hit.Instance.CollisionGroup or "nonpart",
				"canCollide", hit.Instance:IsA("BasePart") and hit.Instance.CanCollide or "n/a",
				"tagged", ClimbableQuery.is_climbable(hit.Instance), "origin", origin, "direction", direction)
			return nil
		end
	end

	return nil
end
function Queries.cast_reachable_grab_top(self, wall_position, wall_normal, root_position, reference_y, max_above_height, wall_instance)
	-- Sample nearby columns around the side hit. When a physical wall part is
	-- known, query its own top first so an invisible climb guide cannot mask it.
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

	local allowed_above_height = max_above_height or Config.MaxGrabHeight
	local sample_offsets = { Vector3.zero }
	local horizontal_normal = Vector.flatten(wall_normal)
	if max_above_height ~= nil and horizontal_normal.Magnitude >= 0.05 then
		horizontal_normal = horizontal_normal.Unit
		local tangent = Vector3.new(-horizontal_normal.Z, 0, horizontal_normal.X)
		local side_step = 0.35
		sample_offsets = {
			Vector3.zero,
			-horizontal_normal * 0.25,
			-horizontal_normal * 0.5,
			-horizontal_normal * 0.85,
			tangent * side_step,
			-tangent * side_step,
			-horizontal_normal * 0.5 + tangent * side_step,
			-horizontal_normal * 0.5 - tangent * side_step,
		}
	end

	local params = self._reachableTopParams or RaycastParams.new()
	self._reachableTopParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local wall_top_params = self._wallTopParams or RaycastParams.new()
	self._wallTopParams = wall_top_params
	wall_top_params.FilterType = Enum.RaycastFilterType.Include
	wall_top_params.FilterDescendantsInstances = {}
	wall_top_params.IgnoreWater = true
	wall_top_params.RespectCanCollide = true

	local best = nil
	local best_height_distance = math.huge
	local first_candidate = nil
	local first_walkable_surface = nil
	local candidate_count = 0
	local reference_height = reference_y or root_position.Y

	local function consider_candidate(candidate, sample_offset, source)
		if not candidate then return end

		local root_height_delta = root_position.Y - candidate.Position.Y
		local reference_height_delta = reference_height - candidate.Position.Y
		local height_distance = math.abs(reference_height_delta)
		local valid_surface = is_grabbable_surface(candidate.Instance)
		local walkable = candidate.Normal.Y >= 0.5
		local above_side_hit = candidate.Position.Y >= wall_position.Y - 0.5
		-- Initial grabs measure "near the top" from the avatar's standing reach,
		-- while the lower-side tolerance remains measured from the root. Existing
		-- traversal callers keep their previous reference-height behavior.
		local lower_reach_delta = if max_above_height ~= nil
			then root_height_delta else reference_height_delta
		local reachable = reference_height_delta >= -allowed_above_height
			and lower_reach_delta <= Config.MaxGrabHeight
			and above_side_hit

		candidate_count += 1
		local candidate_info = {
			Instance = candidate.Instance,
			Group = candidate.Instance:IsA("BasePart") and candidate.Instance.CollisionGroup or "nonpart",
			CanCollide = candidate.Instance:IsA("BasePart") and candidate.Instance.CanCollide or false,
			Tagged = ClimbableQuery.is_climbable(candidate.Instance),
			Normal = candidate.Normal,
			RootHeightDelta = root_height_delta,
			ReferenceHeightDelta = reference_height_delta,
			ValidSurface = valid_surface,
			Walkable = walkable,
			AboveSideHit = above_side_hit,
			Reachable = reachable,
			SampleOffset = sample_offset,
			Source = source,
		}
		if not first_candidate then first_candidate = candidate_info end
		if valid_surface and walkable and not first_walkable_surface then
			first_walkable_surface = candidate_info
		end

		if valid_surface and walkable and reachable and height_distance < best_height_distance then
			best = candidate
			best_height_distance = height_distance
		end
	end

	for _, sample_offset in ipairs(sample_offsets) do
		local sample_origin = origin + sample_offset

		-- Prefer the actual detected collidable wall part. This avoids choosing
		-- a non-collidable Climbable marker above it as the apparent wall top.
		if wall_instance and wall_instance:IsA("BasePart") and wall_instance.CanCollide then
			wall_top_params.FilterDescendantsInstances = { wall_instance }
			local wall_top = Workspace:Raycast(sample_origin, direction, wall_top_params)
			consider_candidate(wall_top, sample_offset, "detected-wall")
		end

		local exclusions = { self.Character }
		for hit_index = 1, Config.MaxTopSurfaceHits do
			params.FilterDescendantsInstances = exclusions
			local candidate = Workspace:Raycast(sample_origin, direction, params)
			if not candidate then
				break
			end

			consider_candidate(candidate, sample_offset, "world")
			table.insert(exclusions, candidate.Instance)
		end
	end

	if not best then
		local diagnostic = first_walkable_surface or first_candidate
		debug_log(self, "grab-top-failed", 0.8, "no eligible reachable top",
			"candidateCount", candidate_count,
			"wallPart", wall_instance and wall_instance:GetFullName(),
			"wallPosition", wall_position,
			"wallNormal", wall_normal,
			"rootY", root_position.Y,
			"referenceY", reference_height,
			"allowedTopAbove", allowed_above_height,
			"allowedTopBelow", Config.MaxGrabHeight,
			"sampleCandidate", diagnostic and diagnostic.Instance:GetFullName(),
			"candidateSource", diagnostic and diagnostic.Source,
			"candidateGroup", diagnostic and diagnostic.Group,
			"candidateCanCollide", diagnostic and diagnostic.CanCollide,
			"candidateTagged", diagnostic and diagnostic.Tagged,
			"candidateNormal", diagnostic and diagnostic.Normal,
			"candidateRootHeightDelta", diagnostic and diagnostic.RootHeightDelta,
			"candidateReferenceHeightDelta", diagnostic and diagnostic.ReferenceHeightDelta,
			"candidateValidSurface", diagnostic and diagnostic.ValidSurface,
			"candidateWalkable", diagnostic and diagnostic.Walkable,
			"candidateAboveSideHit", diagnostic and diagnostic.AboveSideHit,
			"candidateReachable", diagnostic and diagnostic.Reachable,
			"sampleOffset", diagnostic and diagnostic.SampleOffset)
	end
	return best
end
function Queries.detect_surface(self)
	local humanoid = self.Humanoid
	if not humanoid or humanoid.Health <= 0 or humanoid.Sit then return nil end
	local humanoid_state = humanoid:GetState()
	if humanoid_state == Enum.HumanoidStateType.Dead
		or humanoid_state == Enum.HumanoidStateType.Swimming
		or humanoid_state == Enum.HumanoidStateType.Climbing then return nil end
	local root = self.Root
	if not root then
				return nil
	end

	local direction = Vector.flatten(root.CFrame.LookVector)
	if direction.Magnitude < 0.1 then
				return nil
	end
	direction = direction.Unit

	local origin = root.Position + Vector3.new(0, 1.1, 0)
	local wall = Queries.cast_grabbable_side(self, origin, direction * Config.WallReach)
	if not wall then
		debug_log(self, "detect-no-wall", 0.8, "no wall hit", "root", root.Position,
			"look", direction, "move", humanoid.MoveDirection, "reach", Config.WallReach)
		return nil
	end

	-- A held jump alone must not latch the character after they have stopped
	-- approaching the wall. Require current movement intent to have a component
	-- into the detected face; this still permits diagonal approaches.
	local approach = Vector.flatten(humanoid.MoveDirection)
	local toward_wall = Vector.flatten(-wall.Normal)
	local approach_dot = if approach.Magnitude >= 0.05 and toward_wall.Magnitude >= 0.05
		then approach.Unit:Dot(toward_wall.Unit) else -1
	if approach_dot < 0.15 then
		debug_log(self, "detect-movement-gate", 0.8, "movement gate rejected wall", wall.Instance:GetFullName(),
			"group", wall.Instance.CollisionGroup, "move", approach, "towardWall", toward_wall,
			"dot", approach_dot)
		return nil
	end

	local standing_height = self:_standing_height()
	local grab_reference_y = root.Position.Y + standing_height
	local top = Queries.cast_reachable_grab_top(
		self,
		wall.Position,
		wall.Normal,
		root.Position,
		grab_reference_y,
		Config.GrabTopProximity,
		wall.Instance
	)
	if not top then
		debug_log(self, "detect-no-top", 0.8, "no reachable top", "wall", wall.Instance:GetFullName(),
			"wallGroup", wall.Instance.CollisionGroup, "wallNormal", wall.Normal,
			"wallPosition", wall.Position, "rootY", root.Position.Y,
			"reachY", root.Position.Y + self:_standing_height(),
			"move", humanoid.MoveDirection, "nearTopLimit", Config.GrabTopProximity,
			"maxBelow", Config.MaxGrabHeight)
		return nil
	end

	local root_height_delta = root.Position.Y - top.Position.Y
	local reach_height_delta = grab_reference_y - top.Position.Y
	if reach_height_delta < -Config.GrabTopProximity or root_height_delta > Config.MaxGrabHeight then
		debug_log(self, "detect-height", 0.8, "top outside height range", "wall", wall.Instance:GetFullName(),
			"top", top.Instance:GetFullName(), "rootDelta", root_height_delta,
			"reachDelta", reach_height_delta, "topY", top.Position.Y,
			"rootY", root.Position.Y, "reachY", grab_reference_y)
		return nil
	end

	local hang_normal = Vector.flatten(wall.Normal)
	if hang_normal.Magnitude < 0.05 then
				return nil
	end
	hang_normal = hang_normal.Unit
	local hang_position = top.Position + hang_normal * Config.WallGap - Vector3.new(0, Config.HangDrop, 0)
	local body_clear, blocker = Queries.has_hang_body_clearance(self, hang_position, hang_normal)
	if not body_clear then
		debug_log(self, "detect-clearance", 0.8, "hang clearance rejected", "blocker",
			blocker and blocker:GetFullName(), "hangPosition", hang_position, "normal", hang_normal)
		return nil
	end

	local guide = ClimbableQuery.get_guide(top.Instance) or top.Instance
	debug_log(self, "detect-accepted", 0, "surface accepted", "wall", wall.Instance:GetFullName(),
		"wallGroup", wall.Instance.CollisionGroup, "top", top.Instance:GetFullName(),
		"topGroup", top.Instance.CollisionGroup, "guide", guide:GetFullName(),
		"root", root.Position, "topPosition", top.Position, "move", humanoid.MoveDirection)
	return guide, hang_normal, hang_position
end
function Queries.has_hang_body_clearance(self, position, normal)
	local root = self.Root
	local character = self.Character
	if not root or not character or not position or not normal then
		return false
	end

	local facing = Vector.flatten(normal)
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
		probe.CollisionGroup = Config.ClimbableCollisionGroup
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
	overlap_params.CollisionGroup = Config.ClimbableCollisionGroup
	overlap_params.RespectCanCollide = true

	local overlaps = Workspace:GetPartsInPart(probe, overlap_params)
	for _, part in ipairs(overlaps) do
		if part.CanCollide then
						return false, part
		end
	end

	return true
end
function Queries.has_vault_clearance(self, cframe, size, obstacle)
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

return Queries
