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
	if not instance:IsA("BasePart")
		or not instance.CanCollide
		or instance.CollisionGroup == Config.ClimbableCollisionGroup then
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
function Queries.cast_reachable_grab_top(self, wall_position, wall_normal, root_position, reference_y, max_above_height)
	-- Several surfaces can overlap vertically. A single downward ray hits the
	-- highest one first, even when that top is outside grab range. Walk down
	-- through successive hits and choose the nearest eligible walkable top.
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
	local first_candidate = nil
	local first_walkable_surface = nil
	local candidate_count = 0
	for hit_index = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local candidate = Workspace:Raycast(origin, direction, params)
		if not candidate then
			break
		end

		local height_delta = (reference_y or root_position.Y) - candidate.Position.Y
		local height_distance = math.abs(height_delta)
		local allowed_above_height = max_above_height or Config.MaxGrabHeight
		local valid_surface = is_grabbable_surface(candidate.Instance)
		local walkable = candidate.Normal.Y >= 0.5
		local reachable = height_delta >= -allowed_above_height
			and height_delta <= Config.MaxGrabHeight
		candidate_count += 1
		local candidate_info = {
			Instance = candidate.Instance,
			Group = candidate.Instance:IsA("BasePart") and candidate.Instance.CollisionGroup or "nonpart",
			CanCollide = candidate.Instance:IsA("BasePart") and candidate.Instance.CanCollide or false,
			Tagged = ClimbableQuery.is_climbable(candidate.Instance),
			Normal = candidate.Normal,
			HeightDelta = height_delta,
			ValidSurface = valid_surface,
			Walkable = walkable,
			Reachable = reachable,
		}
		if not first_candidate then first_candidate = candidate_info end
		if valid_surface and walkable and not first_walkable_surface then
			first_walkable_surface = candidate_info
		end

		if valid_surface and walkable and reachable and height_distance < best_height_distance then
			best = candidate
			best_height_distance = height_distance
		end

		table.insert(exclusions, candidate.Instance)
	end

	if not best then
		local diagnostic = first_walkable_surface or first_candidate
		debug_log(self, "grab-top-failed", 0.8, "no eligible reachable top",
			"candidateCount", candidate_count,
			"wallPosition", wall_position,
			"wallNormal", wall_normal,
			"rootY", root_position.Y,
			"referenceY", reference_y or root_position.Y,
			"allowedTopAbove", allowed_above_height,
			"allowedTopBelow", Config.MaxGrabHeight,
			"sampleCandidate", diagnostic and diagnostic.Instance:GetFullName(),
			"candidateGroup", diagnostic and diagnostic.Group,
			"candidateCanCollide", diagnostic and diagnostic.CanCollide,
			"candidateTagged", diagnostic and diagnostic.Tagged,
			"candidateNormal", diagnostic and diagnostic.Normal,
			"candidateHeightDelta", diagnostic and diagnostic.HeightDelta,
			"candidateValidSurface", diagnostic and diagnostic.ValidSurface,
			"candidateWalkable", diagnostic and diagnostic.Walkable,
			"candidateReachable", diagnostic and diagnostic.Reachable)
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

	local top = Queries.cast_reachable_grab_top(
		self,
		wall.Position,
		wall.Normal,
		root.Position,
		root.Position.Y,
		Config.GrabTopProximity
	)
	if not top then
		debug_log(self, "detect-no-top", 0.8, "no reachable top", "wall", wall.Instance:GetFullName(),
			"wallGroup", wall.Instance.CollisionGroup, "wallNormal", wall.Normal,
			"wallPosition", wall.Position, "rootY", root.Position.Y,
			"move", humanoid.MoveDirection, "nearTopLimit", Config.GrabTopProximity,
			"maxBelow", Config.MaxGrabHeight)
		return nil
	end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -Config.GrabTopProximity or height_delta > Config.MaxGrabHeight then
		debug_log(self, "detect-height", 0.8, "top outside height range", "wall", wall.Instance:GetFullName(),
			"top", top.Instance:GetFullName(), "delta", height_delta, "topY", top.Position.Y,
			"rootY", root.Position.Y)
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
