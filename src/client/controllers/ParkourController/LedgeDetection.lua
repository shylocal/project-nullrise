local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)
local ClimbableQuery = require(script.Parent.ClimbableQuery)
local Metrics = require(script.Parent.Metrics)
local Queries = require(script.Parent.Queries)

local LedgeDetection = {}

local LATERAL_SAMPLES = { 0, -1.5, 1.5, -3, 3, -4.5, 4.5 }
local LOWER_INWARD_SAMPLES = { 0, 1.5, 3, 5 }
local HIGHER_INWARD_SAMPLES = { -1, 0.5, 1.5, 3, 5, 7 }
local GROUND_INWARD_OFFSETS = { 0.5, 1, 1.75, 2.75, 4, 5.5, 7 }
local GROUND_LATERAL_FACTORS = { 0, -1, 1 }

function LedgeDetection.is_guide_within_mantle_search(self, guide, current_top, normal, tangent)
	local bounds_cframe
	local bounds_size

	if guide:IsA("BasePart") then
		bounds_cframe = guide.CFrame
		bounds_size = guide.Size
	elseif guide:IsA("Model") then
		Metrics.record(self, "ModelBoundsQueries")
		bounds_cframe, bounds_size = guide:GetBoundingBox()
	else
		return false
	end

	local radius = bounds_size.Magnitude * 0.5
	local relative = Vector.flatten(bounds_cframe.Position - current_top)
	local inward = relative:Dot(-normal)
	local lateral = math.abs(relative:Dot(tangent))

	return inward + radius >= -Config.MantleMaxOutward
		and inward - radius <= Config.MantleMaxInward
		and lateral - radius <= Config.MantleMaxLateral
end

local function visit_tagged_guides(self, current_top, normal, tangent, visit)
	local tagged_guides = CollectionService:GetTagged(Config.ClimbableTag)
	Metrics.record(self, "TaggedGuides", #tagged_guides)
	for _, guide in ipairs(tagged_guides) do
		Metrics.record(self, "GuidesVisited")
		if guide:IsDescendantOf(Workspace) then
			local in_bounds = LedgeDetection.is_guide_within_mantle_search(
				self,
				guide,
				current_top,
				normal,
				tangent
			)
			Metrics.record(self, in_bounds and "GuidesInSearchBounds" or "GuidesOutsideSearchBounds")
			if in_bounds then
				visit(guide)
			end
		end
	end
end

function LedgeDetection.select_lower_top(current_top, normal, tangent, tops)
	local best_top = nil
	local best_drop = math.huge
	local best_distance = math.huge

	for _, top in ipairs(tops) do
		if top and top.Normal.Y >= 0.5 then
			local relative = top.Position - current_top
			local drop = current_top.Y - top.Position.Y
			local inward = relative:Dot(-normal)
			local lateral_gap = math.abs(Vector.flatten(relative):Dot(tangent))
			local in_vertical_range = drop >= 0.5 and drop <= Config.MantleMaxRise
			local in_reach = inward >= -Config.MantleMaxOutward
				and inward <= Config.MantleMaxInward
				and lateral_gap <= Config.MantleMaxLateral

			if in_vertical_range and in_reach then
				local horizontal_distance = Vector.flatten(top.Position - current_top).Magnitude
				if drop < best_drop
					or (math.abs(drop - best_drop) < 1e-4 and horizontal_distance < best_distance) then
					best_top = top
					best_drop = drop
					best_distance = horizontal_distance
				end
			end
		end
	end

	return best_top
end

function LedgeDetection.find_lower_ledge(self, current_top, normal, tangent)
	local best_top = nil

	visit_tagged_guides(self, current_top, normal, tangent, function(guide)
		for _, lateral_offset in ipairs(LATERAL_SAMPLES) do
			for _, inward_offset in ipairs(LOWER_INWARD_SAMPLES) do
				Metrics.record(self, "GuideColumns")
				local sample_position = current_top
					+ tangent * lateral_offset
					- normal * inward_offset
				local tops = Queries.get_guide_tops(self, guide, sample_position)
				local selected = LedgeDetection.select_lower_top(
					current_top,
					normal,
					tangent,
					tops
				)
				if selected then
					if best_top then
						best_top = LedgeDetection.select_lower_top(
							current_top,
							normal,
							tangent,
							{ best_top, selected }
						)
					else
						best_top = selected
					end
				end
			end
		end
	end)

	return best_top
end

function LedgeDetection.get_ledge_outward_normal(self, top, reference_position)
	if not top or not top.Instance or not top.Instance:IsA("BasePart") then
		return nil
	end

	local part = top.Instance
	local guide = top.Guide or ClimbableQuery.get_guide(part) or part
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
		local hit = Queries.cast_climbable_side(self, origin, -outward * probe_length)
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

function LedgeDetection.select_higher_top(current_top, normal, tangent, root_y, tops)
	local best_top = nil
	local best_height = math.huge
	local best_distance = math.huge

	for _, top in ipairs(tops) do
		if top and top.Normal.Y >= 0.5 then
			if not (
				top.Instance
				and top.Instance:IsA("BasePart")
				and top.Instance.CollisionGroup == Config.ClimbableCollisionGroup
				and not ClimbableQuery.is_climbable(top.Instance)
			) then
				local relative = top.Position - current_top
				local inward = relative:Dot(-normal)
				local lateral = math.abs(Vector.flatten(relative):Dot(tangent))
				local rise = top.Position.Y - current_top.Y
				local root_height_delta = root_y - top.Position.Y
				local in_vertical_range = rise > Config.MantleMinRise
					and rise <= Config.MantleMaxRise
					and root_height_delta >= -(Config.MantleMaxRise + Config.HangDrop)
					and root_height_delta <= Config.MaxGrabHeight
				local in_reach = inward >= -Config.MantleMaxOutward
					and inward <= Config.MantleMaxInward
					and lateral <= Config.MantleMaxLateral

				if in_vertical_range and in_reach then
					local horizontal_distance = Vector.flatten(relative).Magnitude
					if rise < best_height
						or (math.abs(rise - best_height) < 1e-4 and horizontal_distance < best_distance) then
						best_top = top
						best_height = rise
						best_distance = horizontal_distance
					end
				end
			end
		end
	end

	return best_top
end

function LedgeDetection.find_higher_ledge(self, current_top, normal, tangent, root_y)
	if not root_y then
		return nil
	end

	local best_top = nil
	visit_tagged_guides(self, current_top, normal, tangent, function(guide)
		for _, lateral_offset in ipairs(LATERAL_SAMPLES) do
			for _, inward_offset in ipairs(HIGHER_INWARD_SAMPLES) do
				Metrics.record(self, "GuideColumns")
				local sample_position = current_top
					+ tangent * lateral_offset
					- normal * inward_offset
				local tops = Queries.get_guide_tops(self, guide, sample_position)
				local selected = LedgeDetection.select_higher_top(
					current_top,
					normal,
					tangent,
					root_y,
					tops
				)
				if selected then
					if best_top then
						best_top = LedgeDetection.select_higher_top(
							current_top,
							normal,
							tangent,
							root_y,
							{ best_top, selected }
						)
					else
						best_top = selected
					end
				end
			end
		end
	end)

	return best_top
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
		Metrics.record(self, "Raycasts")
		Metrics.record(self, "MantleGroundRaycasts")
		local hit = Workspace:Raycast(origin, direction, params)
		if not hit then
			return nil
		end

		local is_climbable_group = hit.Instance:IsA("BasePart")
			and hit.Instance.CollisionGroup == Config.ClimbableCollisionGroup
		if not is_climbable_group then
			return hit
		end

		table.insert(exclusions, hit.Instance)
	end

	return nil
end

function LedgeDetection.find_ground_mantle(self, current_top, normal, tangent, current_climbable, root_y, standing_height, root_size_x)
	if not root_y or not standing_height or not root_size_x then
		return nil
	end

	local outward_normal = Vector.flatten(normal)
	local sideways = Vector.flatten(tangent)
	if outward_normal.Magnitude < 0.05 or sideways.Magnitude < 0.05 then
		return nil
	end
	outward_normal = outward_normal.Unit
	sideways = sideways.Unit

	local max_rise = Config.GroundMantleMaxRise
	local lateral_step = math.max(root_size_x * 0.45, 0.4)
	local ray_origin_y = current_top.Y + max_rise + standing_height + 2
	local ray_length = max_rise + standing_height + 4
	local best_ground = nil
	local best_score = math.huge

	for _, inward_offset in ipairs(GROUND_INWARD_OFFSETS) do
		for _, lateral_factor in ipairs(GROUND_LATERAL_FACTORS) do
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
				local is_current_surface = ground.Instance == current_climbable
					or (ground_guide ~= nil and ground_guide == current_climbable)
				local rise = ground.Position.Y - current_top.Y
				local relative = ground.Position - current_top
				local inward_distance = relative:Dot(-outward_normal)
				local lateral_distance = math.abs(Vector.flatten(relative):Dot(sideways))
				local root_to_floor = root_y - ground.Position.Y
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

	return best_ground
end

return LedgeDetection
