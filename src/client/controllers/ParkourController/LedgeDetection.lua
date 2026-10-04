--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vector = require(ReplicatedStorage.shared.utility.Vector)
local SharedConfig = require(ReplicatedStorage.shared.config)

local Metrics = require(script.Parent.Metrics)
local Queries = require(script.Parent.Queries)
local ClimbableIndex = require(script.Parent.ClimbableIndex)
local QueryContext = require(script.Parent.QueryContext)
local Types = require(script.Parent.Types)

type Controller = Types.Controller
type GuideTop = Types.GuideTop

local Config = SharedConfig.Parkour
local CLIMBABLE_GROUP = SharedConfig.World.CollisionGroups.Climbable

local LedgeDetection = {}

local LATERAL_SAMPLES = { 0, -1.5, 1.5, -3, 3, -4.5, 4.5 }
local LOWER_INWARD_SAMPLES = { 0, 1.5, 3, 5 }
local HIGHER_INWARD_SAMPLES = { -1, 0.5, 1.5, 3, 5, 7 }
local GROUND_INWARD_OFFSETS = { 0.5, 1, 1.75, 2.75, 4, 5.5, 7 }
local GROUND_LATERAL_FACTORS = { 0, -1, 1 }

function LedgeDetection.is_guide_within_mantle_search(
	self: Controller,
	guide: Instance,
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3
): boolean
	if not guide:IsA("BasePart") and not guide:IsA("Model") then
		return false
	end
	local bounds_cframe, bounds_size = self.Climbables:Bounds(guide)

	local radius = bounds_size.Magnitude * 0.5
	local relative = Vector.flatten(bounds_cframe.Position - current_top)
	local inward = relative:Dot(-normal)
	local lateral = math.abs(relative:Dot(tangent))

	return inward + radius >= -Config.MantleMaxOutward
		and inward - radius <= Config.MantleMaxInward
		and lateral - radius <= Config.MantleMaxLateral
end

-- Oriented box around current_top that contains every point a mantle search
-- can accept: inward [-MantleMaxOutward, MantleMaxInward], lateral
-- +-MantleMaxLateral along `tangent`, vertical +-(MantleMaxRise + 1). Guides
-- outside it cannot yield a valid top, so the index lookup selects the same
-- guides as scanning every tagged guide.
function LedgeDetection.mantle_search_box(current_top: Vector3, normal: Vector3, tangent: Vector3): (CFrame?, Vector3?)
	local inward = -Vector.flatten(normal)
	if inward.Magnitude < 0.05 then
		return nil
	end
	inward = inward.Unit
	local right = inward:Cross(Vector3.yAxis).Unit
	local inward_center = (Config.MantleMaxInward - Config.MantleMaxOutward) * 0.5
	local inward_half = (Config.MantleMaxInward + Config.MantleMaxOutward) * 0.5
	local center = current_top + inward * inward_center
	local cframe = CFrame.fromMatrix(center, right, Vector3.yAxis, -inward)

	-- The lateral limit is measured along `tangent`, which need not be exactly
	-- perpendicular to the normal; widen the box to cover that skew.
	local flat_tangent = Vector.flatten(tangent)
	local lateral_half: number
	local along_right = flat_tangent.Magnitude >= 0.05 and math.abs(flat_tangent.Unit:Dot(right)) or 0
	if along_right < 0.1 then
		lateral_half = Config.MantleMaxLateral + Config.MantleMaxInward + Config.MantleMaxOutward
	else
		local along_inward = math.abs(flat_tangent.Unit:Dot(inward))
		local max_inward = math.max(Config.MantleMaxInward, Config.MantleMaxOutward)
		lateral_half = (Config.MantleMaxLateral + max_inward * along_inward) / along_right
	end
	local vertical_half = Config.MantleMaxRise + 1
	return cframe, Vector3.new(lateral_half * 2, vertical_half * 2, inward_half * 2)
end

local function visit_tagged_guides(
	self: Controller,
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3,
	visit: (Instance) -> ()
)
	local box_cframe, box_size = LedgeDetection.mantle_search_box(current_top, normal, tangent)
	if not box_cframe or not box_size then
		return
	end
	local candidates = self.Climbables:QueryBox(box_cframe, box_size)
	Metrics.record(self, "TaggedGuides", #candidates)
	for _, guide in ipairs(candidates) do
		Metrics.record(self, "GuidesVisited")
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

function LedgeDetection.select_lower_top(
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3,
	tops: { GuideTop }
): GuideTop?
	local best_top: GuideTop? = nil
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

function LedgeDetection.find_lower_ledge(
	self: Controller,
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3
): GuideTop?
	local best_top: GuideTop? = nil

	visit_tagged_guides(self, current_top, normal, tangent, function(guide: Instance)
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

function LedgeDetection.get_ledge_outward_normal(
	self: Controller,
	top: GuideTop?,
	reference_position: Vector3
): Vector3?
	if not top or not top.Instance or not top.Instance:IsA("BasePart") then
		return nil
	end

	local part = top.Instance
	local guide = top.Guide or self.Climbables:GuideOf(part) or part
	local axes: { Vector3 } = {}

	local function add_axis(axis: Vector3)
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
	local best_normal: Vector3? = nil
	local best_score = math.huge

	for _, outward in ipairs(axes) do
		local origin = Vector3.new(top.Position.X, probe_y, top.Position.Z)
			+ outward * probe_length
		local hit = Queries.cast_climbable_side(self, origin, -outward * probe_length)
		if hit and (self.Climbables:GuideOf(hit.Instance) or hit.Instance) == guide then
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

function LedgeDetection.select_higher_top(
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3,
	root_y: number,
	tops: { GuideTop },
	climbables: ClimbableIndex.ClimbableIndex
): GuideTop?
	local best_top: GuideTop? = nil
	local best_height = math.huge
	local best_distance = math.huge

	for _, top in ipairs(tops) do
		if top and top.Normal.Y >= 0.5 then
			if not (
				top.Instance
				and top.Instance:IsA("BasePart")
				and top.Instance.CollisionGroup == CLIMBABLE_GROUP
				and not climbables:IsClimbable(top.Instance)
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

function LedgeDetection.find_higher_ledge(
	self: Controller,
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3,
	root_y: number?
): GuideTop?
	if not root_y then
		return nil
	end

	local best_top: GuideTop? = nil
	visit_tagged_guides(self, current_top, normal, tangent, function(guide: Instance)
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
					tops,
					self.Climbables
				)
				if selected then
					if best_top then
						best_top = LedgeDetection.select_higher_top(
							current_top,
							normal,
							tangent,
							root_y,
							{ best_top, selected },
							self.Climbables
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

local function classify_mantle_ground(hit: RaycastResult): QueryContext.Verdict
	local is_climbable_group = hit.Instance:IsA("BasePart")
		and hit.Instance.CollisionGroup == CLIMBABLE_GROUP
	return if is_climbable_group then "skip" else "accept"
end

local function cast_mantle_ground(self: Controller, origin: Vector3, direction: Vector3): RaycastResult?
	return self.Query:Pierce(
		origin,
		direction,
		self.Query.Params.MantleGround,
		classify_mantle_ground,
		Config.MaxTopSurfaceHits,
		"MantleGroundRaycasts"
	)
end

function LedgeDetection.find_ground_mantle(
	self: Controller,
	current_top: Vector3,
	normal: Vector3,
	tangent: Vector3,
	current_climbable: Instance,
	root_y: number?,
	standing_height: number?,
	root_size_x: number?
): RaycastResult?
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
	local best_ground: RaycastResult? = nil
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
				local ground_guide = self.Climbables:GuideOf(ground.Instance)
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
