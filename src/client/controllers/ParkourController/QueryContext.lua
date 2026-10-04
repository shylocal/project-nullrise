--!strict
-- Owns every RaycastParams/OverlapParams used by one ParkourController and
-- funnels every Workspace query through one place so each is counted
-- (Metrics: opt-in named counters plus the always-on per-frame ray count).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)

local Metrics = require(script.Parent.Metrics)

export type Verdict = "accept" | "skip" | "stop"

export type Params = {
	CastAny: RaycastParams,
	CastSolid: RaycastParams,
	GrabbableSide: RaycastParams,
	ClimbableSide: RaycastParams,
	ReachableTop: RaycastParams,
	WallTop: RaycastParams,
	GuideTop: RaycastParams,
	TallWallTop: RaycastParams,
	MantleGround: RaycastParams,
	VaultTop: RaycastParams,
	VaultSupport: RaycastParams,
}

export type Overlap = {
	Hang: OverlapParams,
	Vault: OverlapParams,
}

local QueryContext = {}
QueryContext.__index = QueryContext

export type QueryContext = typeof(setmetatable(
	{} :: {
		Params: Params,
		Overlap: Overlap,
		_controller: any,
		_base: { [RaycastParams]: { Instance } },
	},
	QueryContext
))

function QueryContext.new(controller: any): QueryContext
	local character = controller.Character
	assert(typeof(character) == "Instance", "QueryContext.new: controller.Character must be an Instance")

	local base: { [RaycastParams]: { Instance } } = {}
	local function raycast_params(filter_type: Enum.RaycastFilterType, respect_can_collide: boolean): RaycastParams
		local params = RaycastParams.new()
		params.FilterType = filter_type
		params.IgnoreWater = true
		params.RespectCanCollide = respect_can_collide
		local list = if filter_type == Enum.RaycastFilterType.Exclude then { character } else {}
		params.FilterDescendantsInstances = list
		base[params] = list
		return params
	end
	local exclude = Enum.RaycastFilterType.Exclude
	local include = Enum.RaycastFilterType.Include

	local hang_overlap = OverlapParams.new()
	hang_overlap.FilterType = exclude
	-- Collision filtering excludes Climbable helper geometry from hang clearance.
	hang_overlap.CollisionGroup = Config.World.CollisionGroups.Climbable
	hang_overlap.RespectCanCollide = true

	local vault_overlap = OverlapParams.new()
	vault_overlap.FilterType = exclude
	vault_overlap.RespectCanCollide = true

	return setmetatable({
		Params = {
			CastAny = raycast_params(exclude, false),
			CastSolid = raycast_params(exclude, true),
			GrabbableSide = raycast_params(exclude, false),
			ClimbableSide = raycast_params(exclude, false),
			ReachableTop = raycast_params(exclude, false),
			WallTop = raycast_params(include, true),
			GuideTop = raycast_params(include, false),
			TallWallTop = raycast_params(include, true),
			MantleGround = raycast_params(exclude, true),
			VaultTop = raycast_params(include, true),
			VaultSupport = raycast_params(exclude, true),
		},
		Overlap = {
			Hang = hang_overlap,
			Vault = vault_overlap,
		},
		_controller = controller,
		_base = base,
	}, QueryContext)
end

-- One counted Workspace raycast. `metric` names an extra opt-in counter.
function QueryContext.Raycast(
	self: QueryContext,
	origin: Vector3,
	direction: Vector3,
	params: RaycastParams,
	metric: string?
): RaycastResult?
	local controller = self._controller
	Metrics.record(controller, "Raycasts")
	if metric then
		Metrics.record(controller, metric)
	end
	Metrics.count_ray(controller)
	return Workspace:Raycast(origin, direction, params)
end

-- Sets a one-element Include filter and returns the params.
function QueryContext.Include(_self: QueryContext, params: RaycastParams, instance: Instance): RaycastParams
	params.FilterDescendantsInstances = { instance }
	return params
end

-- Sets an Exclude filter of the params' base list plus `extra`.
function QueryContext.Exclude(self: QueryContext, params: RaycastParams, extra: { Instance }): RaycastParams
	local list = table.clone(self._base[params] or {})
	for _, instance in extra do
		table.insert(list, instance)
	end
	params.FilterDescendantsInstances = list
	return params
end

-- Casts repeatedly along one ray: "accept" returns the hit, "stop" returns
-- nil, "skip" excludes the hit instance and casts again (at most max_hits
-- casts). The filter is reset to the params' base list first.
function QueryContext.Pierce(
	self: QueryContext,
	origin: Vector3,
	direction: Vector3,
	params: RaycastParams,
	classify: (RaycastResult) -> Verdict,
	max_hits: number,
	metric: string?
): RaycastResult?
	params.FilterDescendantsInstances = self._base[params] or {}
	for _ = 1, max_hits do
		local hit = self:Raycast(origin, direction, params, metric)
		if not hit then
			return nil
		end
		local verdict = classify(hit)
		if verdict == "accept" then
			return hit
		elseif verdict == "stop" then
			return nil
		end
		params:AddToFilter(hit.Instance)
	end
	return nil
end

function QueryContext.PartsInPart(self: QueryContext, part: BasePart, overlap: OverlapParams): { BasePart }
	Metrics.record(self._controller, "OverlapQueries")
	return Workspace:GetPartsInPart(part, overlap)
end

function QueryContext.PartBoundsInBox(self: QueryContext, cframe: CFrame, size: Vector3, overlap: OverlapParams): { BasePart }
	Metrics.record(self._controller, "OverlapQueries")
	return Workspace:GetPartBoundsInBox(cframe, size, overlap)
end

return QueryContext
