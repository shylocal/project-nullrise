-- Parkour spatial queries. Every Workspace query goes through the
-- controller's QueryContext (self.Query); Climbable membership and guide
-- bounds come from the ClimbableIndex (self.Climbables).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local SharedConfig = require(ReplicatedStorage.shared.config)

local Metrics = require(script.Parent.Metrics)

local Config = SharedConfig.Parkour
local CLIMBABLE_GROUP = SharedConfig.World.CollisionGroups.Climbable

local Queries = {}

function Queries.cast(self, origin, direction, respect_can_collide)
	local params = if respect_can_collide == true then self.Query.Params.CastSolid else self.Query.Params.CastAny
	return self.Query:Raycast(origin, direction, params)
end

local function is_grabbable_surface(self, instance)
	if not instance:IsA("BasePart") then
		return false
	end

	-- Explicitly tagged climb guides are authored as invisible, non-collidable
	-- query volumes. Keep those eligible while continuing to ignore unrelated
	-- non-collidable parts and the helper collision group.
	local is_guide = self.Climbables:IsClimbable(instance)
	if not is_guide
		and (not instance.CanCollide
			or instance.CollisionGroup == CLIMBABLE_GROUP) then
		return false
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	return not (model and model:FindFirstChildOfClass("Humanoid"))
end

function Queries.cast_grabbable_side(self, origin, direction)
	return self.Query:Pierce(origin, direction, self.Query.Params.GrabbableSide, function(hit)
		if is_grabbable_surface(self, hit.Instance) then
			return "accept"
		end
		-- Ignore climbable proxy geometry and decorative non-collidable parts.
		-- Other solid parts are valid grab surfaces only when they passed the
		-- grabbable-surface check above.
		if hit.Instance:IsA("BasePart")
			and (not hit.Instance.CanCollide
				or hit.Instance.CollisionGroup == CLIMBABLE_GROUP) then
			return "skip"
		end
		return "stop"
	end, Config.MaxTopSurfaceHits)
end

-- Preserve the stable tagged-guide probe for traversal and corner following.
-- Unlike the generic grab probe, it never adopts an untagged solid wall.
function Queries.cast_climbable_side(self, origin, direction)
	return self.Query:Pierce(origin, direction, self.Query.Params.ClimbableSide, function(hit)
		if self.Climbables:IsClimbable(hit.Instance) then
			return "accept"
		end
		-- Skip decorative non-collidable geometry, but do not ray through
		-- solid non-climbable obstructions.
		if not hit.Instance:IsA("BasePart") or hit.Instance.CanCollide then
			return "stop"
		end
		return "skip"
	end, Config.MaxTopSurfaceHits)
end

local function is_tall_wall_candidate(self, instance, normal)
	if not instance:IsA("BasePart")
		or not instance.CanCollide
		or self.Climbables:IsClimbable(instance)
		or math.abs(normal.Y) >= 0.5 then
		return false
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false
	end

	-- Use projected world-space height so rotated tall parts qualify even when
	-- their height is along local X or Z rather than local Y.
	local cframe = instance.CFrame
	local size = instance.Size
	local world_height = math.abs(cframe.RightVector.Y) * size.X
		+ math.abs(cframe.UpVector.Y) * size.Y
		+ math.abs(cframe.LookVector.Y) * size.Z
	return world_height >= Config.TallWallMinHeight
end

local function cast_tall_wall_top(self, wall, wall_position, root_position)
	local standing_height = self:_standing_height()
	local origin = Vector3.new(
		wall_position.X,
		root_position.Y + Config.MaxGrabHeight + standing_height + 2,
		wall_position.Z
	) - wall.Normal * 0.1
	local direction = Vector3.new(
		0,
		-(Config.MaxGrabHeight * 2 + standing_height + 4),
		0
	)

	local params = self.Query:Include(self.Query.Params.TallWallTop, wall.Instance)
	local top = self.Query:Raycast(origin, direction, params)
	if not top or top.Normal.Y < 0.5 then
		return nil
	end

	-- Grab only when the lip is within standing reach. This avoids catching a
	-- tall wall from low on its face while allowing a jump that reaches the edge.
	local top_above_root = top.Position.Y - root_position.Y
	if top_above_root > standing_height + Config.TallWallTopReachMargin
		or top_above_root < -Config.MaxGrabHeight then
		return nil
	end
	return top
end

-- max_above_height and wall_instance are optional context supplied by callers
-- that want extra local sampling around the detected wall. Existing traversal
-- callers omit them, preserving the stable single-column behavior.
function Queries.cast_reachable_grab_top(
	self,
	wall_position,
	wall_normal,
	root_position,
	reference_y,
	max_above_height,
	wall_instance
)
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

	local query = self.Query
	local best = nil
	local best_height_distance = math.huge
	local reference_height = reference_y or root_position.Y

	local function consider_candidate(candidate)
		if not candidate then return end

		local root_height_delta = root_position.Y - candidate.Position.Y
		local reference_height_delta = reference_height - candidate.Position.Y
		local height_distance = math.abs(reference_height_delta)
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

		-- Check the cheap geometric conditions before the guide lookup.
		if walkable and reachable and height_distance < best_height_distance
			and self.Climbables:IsClimbable(candidate.Instance) then
			best = candidate
			best_height_distance = height_distance
		end
	end

	local function consider_and_skip(candidate)
		consider_candidate(candidate)
		return "skip"
	end

	for _, sample_offset in ipairs(sample_offsets) do
		local sample_origin = origin + sample_offset

		-- Prefer the actual detected collidable wall part. This avoids choosing
		-- a non-collidable Climbable marker above it as the apparent wall top.
		if wall_instance and wall_instance:IsA("BasePart") and wall_instance.CanCollide then
			local wall_top_params = query:Include(query.Params.WallTop, wall_instance)
			consider_candidate(query:Raycast(sample_origin, direction, wall_top_params))
		end

		query:Pierce(sample_origin, direction, query.Params.ReachableTop, consider_and_skip, Config.MaxTopSurfaceHits)
	end

	return best
end

function Queries.get_guide_top(self, guide, sample_position)
	local box_cframe
	local box_size
	local hit_instance
	if guide:IsA("BasePart") then
		box_cframe, box_size = self.Climbables:Bounds(guide)
		hit_instance = guide
	elseif guide:IsA("Model") then
		box_cframe, box_size = self.Climbables:Bounds(guide)
		hit_instance = guide.PrimaryPart or guide:FindFirstChildWhichIsA("BasePart", true)
	else
		return nil
	end
	if not hit_instance then return nil end

	-- Sample the actual highest walkable surface at the guide's horizontal
	-- center. This handles cylinders whose long axis is local X, including
	-- cylinders rotated upright, without assuming local Y is their top.
	local query = self.Query
	local params = query:Include(query.Params.GuideTop, guide)
	local ray_length = box_size.Magnitude * 2 + 8
	local ray_origin = Vector3.new(
		sample_position and sample_position.X or box_cframe.Position.X,
		box_cframe.Position.Y + box_size.Magnitude + 4,
		sample_position and sample_position.Z or box_cframe.Position.Z
	)
	local sampled_top = query:Raycast(
		ray_origin,
		Vector3.new(0, -ray_length, 0),
		params,
		"GuideTopRaycasts"
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

	-- A caller-supplied sample is asking for the surface at that specific
	-- horizontal location (not the guide's bounding-box center). Falling back
	-- to the box center here can fabricate a distant top at a corner seam and
	-- make coverage checks nondeterministic as the character moves.
	if sample_position then
		return nil
	end

	-- Retain the oriented-box fallback for center queries whose top cannot be
	-- sampled, but only when the box's own up axis is sufficiently walkable.
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

function Queries.get_guide_tops(self, guide, sample_position)
	Metrics.record(self, "GuideTopQueries")
	local first_top = Queries.get_guide_top(self, guide, sample_position)
	if not first_top then return {} end

	local tops = { first_top }
	local query = self.Query
	local params = query:Include(query.Params.GuideTop, guide)

	local sample_x = sample_position and sample_position.X or first_top.Position.X
	local sample_z = sample_position and sample_position.Z or first_top.Position.Z
	local ray_length = first_top.BoxSize.Magnitude * 2 + 8
	local ray_origin = Vector3.new(sample_x, first_top.Position.Y - 0.05, sample_z)
	local previous_y = first_top.Position.Y

	-- Starting just below each found surface exposes the next lower part in a
	-- stacked Model without globally ray-filtering out the whole tagged guide.
	for _ = 2, Config.MaxTopSurfaceHits do
		local hit = query:Raycast(
			ray_origin,
			Vector3.new(0, -ray_length, 0),
			params,
			"GuideStackRaycasts"
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
		return nil
	end

	local top = nil
	local tall_wall = false
	if self.Climbables:IsClimbable(wall.Instance) then
		top = Queries.cast_reachable_grab_top(
			self,
			wall.Position,
			wall.Normal,
			root.Position,
			root.Position.Y
		)
		if top and not self.Climbables:IsClimbable(top.Instance) then
			top = nil
		end
	end

	-- Keep the stable tagged-guide path first. Tall solid walls require
	-- deliberate forward intent as well as Jump; Space alone must not latch.
	if not top and self.Input:IsDown(Actions.Forward) then
		local physical_wall = Queries.cast(self, origin, direction * Config.WallReach, true)
		if physical_wall and is_tall_wall_candidate(self, physical_wall.Instance, physical_wall.Normal) then
			local physical_top = cast_tall_wall_top(self, physical_wall, physical_wall.Position, root.Position)
			if physical_top then
				wall = physical_wall
				top = physical_top
				tall_wall = true
			end
		end
	end
	if not top then
		return nil
	end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -Config.MaxGrabHeight or height_delta > Config.MaxGrabHeight then
		return nil
	end

	local hang_normal = Vector.flatten(wall.Normal)
	if hang_normal.Magnitude < 0.05 then
		return nil
	end
	hang_normal = hang_normal.Unit

	-- Tagged guides retain the stable stand-off. Solid tall walls use the
	-- smallest stand-off that clears the root collision envelope.
	local edge_gap = Config.WallGap
	if tall_wall then
		-- The top ray samples 0.1 studs inside the wall footprint; compensate
		-- so the root still stops just outside the physical face.
		edge_gap = root.Size.Z * 0.5 + Config.TallWallEdgeClearance + 0.1
	end
	local hang_position = top.Position + hang_normal * edge_gap - Vector3.new(0, Config.HangDrop, 0)
	local body_clear = Queries.has_hang_body_clearance(self, hang_position, hang_normal)
	if not body_clear then
		return nil
	end

	return self.Climbables:GuideOf(top.Instance) or top.Instance, hang_normal, hang_position, edge_gap
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
	-- Query with a box-shaped probe against exact part geometry. A bounds
	-- query can treat a cylinder's enclosing box as solid, falsely rejecting
	-- otherwise clear positions beside its curved surface. The probe is only
	-- the query volume: CanQuery = false keeps it invisible to every other
	-- raycast and overlap query, while GetPartsInPart still uses its geometry.
	local probe = self.HangClearanceProbe
	if not probe or not probe.Parent then
		probe = Instance.new("Part")
		probe.Name = "ParkourHangClearanceProbe"
		probe.Anchored = true
		probe.CanCollide = false
		probe.CanTouch = false
		probe.CanQuery = false
		probe.CollisionGroup = CLIMBABLE_GROUP
		probe.Transparency = 1
		probe.CastShadow = false
		probe.Parent = Workspace
		self.HangClearanceProbe = probe
	end
	probe.Size = root.Size + Vector3.new(0.08, 0.08, 0.08)
	probe.CFrame = target_cframe
	local overlap_params = self.Query.Overlap.Hang
	overlap_params.FilterDescendantsInstances = { character, probe }

	local overlaps = self.Query:PartsInPart(probe, overlap_params)
	for _, part in ipairs(overlaps) do
		if part.CanCollide then
			return false, part
		end
	end

	return true
end

function Queries.has_vault_clearance(self, cframe, size, obstacle)
	local params = self.Query.Overlap.Vault
	params.FilterDescendantsInstances = { self.Character, obstacle }

	local root = self.Root
	if root then
		params.CollisionGroup = root.CollisionGroup
	end

	for _, part in ipairs(self.Query:PartBoundsInBox(cframe, size, params)) do
		if part.CanCollide then
			return false, part
		end
	end

	return true
end

return Queries
