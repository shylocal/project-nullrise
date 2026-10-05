--!strict
-- Parkour query counters. Named profiling counters are opt-in (the character's
-- ParkourQueryMetrics attribute); the per-frame ray counters always count so
-- the frame budget can be watched in Studio.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.shared.config)

local IS_STUDIO = RunService:IsStudio()

-- State held by a controller as `controller.Metrics`.
export type State = {
	Enabled: boolean,
	Stats: { [string]: number },
	RaysThisFrame: number,
	MaxRaysPerFrame: number,
	LastBudgetWarnAt: number,
	-- Rays cast this frame inside a ledge search; excluded from FrameRayBudget.
	SearchRaysThisFrame: number,
	-- Nesting depth of measure_search, and rays cast by the current search.
	SearchDepth: number,
	SearchRays: number,
	LastSearchWarnAt: number,
}

-- Anything that carries metrics state (the controller, or a spec fake).
export type Host = { Metrics: State }

local Metrics = {}

local REPORT_FIELDS = {
	"Raycasts",
	"OverlapQueries",
	"TaggedGuides",
	"GuidesVisited",
	"GuidesInSearchBounds",
	"GuidesOutsideSearchBounds",
	"GuideColumns",
	"GuideTopQueries",
	"GuideTopRaycasts",
	"GuideStackRaycasts",
	"MantleGroundRaycasts",
	"SearchMilliseconds",
}

function Metrics.new(enabled: boolean): State
	return {
		Enabled = enabled == true,
		Stats = {},
		RaysThisFrame = 0,
		MaxRaysPerFrame = 0,
		LastBudgetWarnAt = -math.huge,
		SearchRaysThisFrame = 0,
		SearchDepth = 0,
		SearchRays = 0,
		LastSearchWarnAt = -math.huge,
	}
end

function Metrics.is_enabled(controller: Host): boolean
	return controller.Metrics.Enabled == true
end

function Metrics.set_enabled(controller: Host, enabled: boolean)
	controller.Metrics.Enabled = enabled == true
end

function Metrics.record(controller: Host, name: string, amount: number?)
	local metrics = controller.Metrics
	if not metrics.Enabled then
		return
	end
	local stats = metrics.Stats
	stats[name] = (stats[name] or 0) + (amount or 1)
end

-- Called first in every controller step.
function Metrics.begin_frame(controller: Host)
	controller.Metrics.RaysThisFrame = 0
	controller.Metrics.SearchRaysThisFrame = 0
end

-- Counts one raycast, whether or not profiling is on. Rays inside a ledge
-- search count toward that search's SearchRayBudget; every other ray counts
-- toward FrameRayBudget, the steady per-frame cost.
function Metrics.count_ray(controller: Host)
	local metrics = controller.Metrics
	local rays = metrics.RaysThisFrame + 1
	metrics.RaysThisFrame = rays
	if rays > metrics.MaxRaysPerFrame then
		metrics.MaxRaysPerFrame = rays
	end
	if metrics.SearchDepth > 0 then
		metrics.SearchRaysThisFrame += 1
		metrics.SearchRays += 1
		return
	end
	local frame_rays = rays - metrics.SearchRaysThisFrame
	if IS_STUDIO and frame_rays == Config.Parkour.FrameRayBudget + 1 then
		local now = os.clock()
		if now - metrics.LastBudgetWarnAt >= Config.Parkour.BudgetWarnInterval then
			metrics.LastBudgetWarnAt = now
			warn(string.format(
				"[ParkourMetrics] %d+ raycasts in one frame (budget %d)",
				frame_rays,
				Config.Parkour.FrameRayBudget
			))
		end
	end
end

function Metrics.snapshot(controller: Host): { [string]: number }
	local metrics = controller.Metrics
	local snapshot = table.clone(metrics.Stats)
	snapshot.RaysThisFrame = metrics.RaysThisFrame
	snapshot.MaxRaysPerFrame = metrics.MaxRaysPerFrame
	return snapshot
end

-- Clears the opt-in counters. MaxRaysPerFrame keeps the session maximum.
function Metrics.reset(controller: Host)
	table.clear(controller.Metrics.Stats)
end

-- Runs one ledge search. Its rays are checked against SearchRayBudget instead
-- of FrameRayBudget. With profiling on, the counters are reset first and
-- printed afterwards with the search's duration.
function Metrics.measure_search(controller: Host, name: string, search: () -> ())
	local metrics = controller.Metrics
	local outermost = metrics.SearchDepth == 0
	if outermost then
		metrics.SearchRays = 0
	end
	metrics.SearchDepth += 1

	local profiling = Metrics.is_enabled(controller)
	local started_at = os.clock()
	if profiling then
		Metrics.reset(controller)
	end

	-- The depth must unwind even if the search errors.
	local result = table.pack(pcall(search))
	metrics.SearchDepth -= 1
	if not result[1] then
		error(result[2], 0)
	end

	if outermost and IS_STUDIO and metrics.SearchRays > Config.Parkour.SearchRayBudget then
		local now = os.clock()
		if now - metrics.LastSearchWarnAt >= Config.Parkour.BudgetWarnInterval then
			metrics.LastSearchWarnAt = now
			warn(string.format(
				"[ParkourMetrics] %s search cast %d raycasts (budget %d)",
				name,
				metrics.SearchRays,
				Config.Parkour.SearchRayBudget
			))
		end
	end

	if not profiling then
		return
	end

	Metrics.record(controller, "SearchMilliseconds", (os.clock() - started_at) * 1000)

	local stats = Metrics.snapshot(controller)
	local values = {}
	for _, field in REPORT_FIELDS do
		table.insert(values, string.format("%s=%s", field, tostring(stats[field] or 0)))
	end
	print(string.format("[ParkourMetrics] %s %s", name, table.concat(values, " ")))
end

return Metrics
