-- Parkour query counters. Named profiling counters are opt-in (the character's
-- ParkourQueryMetrics attribute); the per-frame ray counters always count so
-- the frame budget can be watched in Studio.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.shared.config)

local IS_STUDIO = RunService:IsStudio()

local Metrics = {}

local REPORT_FIELDS = {
	"Raycasts",
	"OverlapQueries",
	"TaggedGuides",
	"GuidesVisited",
	"GuidesInSearchBounds",
	"GuidesOutsideSearchBounds",
	"ModelBoundsQueries",
	"GuideColumns",
	"GuideTopQueries",
	"GuideTopRaycasts",
	"GuideStackRaycasts",
	"MantleGroundRaycasts",
	"SearchMilliseconds",
}

-- State held by a controller as `controller.Metrics`.
function Metrics.new(enabled)
	return {
		Enabled = enabled == true,
		Stats = {},
		RaysThisFrame = 0,
		MaxRaysPerFrame = 0,
		LastBudgetWarnAt = -math.huge,
	}
end

function Metrics.is_enabled(controller)
	return controller.Metrics.Enabled == true
end

function Metrics.set_enabled(controller, enabled)
	controller.Metrics.Enabled = enabled == true
end

function Metrics.record(controller, name, amount)
	local metrics = controller.Metrics
	if not metrics.Enabled then
		return
	end
	local stats = metrics.Stats
	stats[name] = (stats[name] or 0) + (amount or 1)
end

-- Called first in every controller step.
function Metrics.begin_frame(controller)
	controller.Metrics.RaysThisFrame = 0
end

-- Counts one raycast against the frame budget, whether or not profiling is on.
function Metrics.count_ray(controller)
	local metrics = controller.Metrics
	local rays = metrics.RaysThisFrame + 1
	metrics.RaysThisFrame = rays
	if rays > metrics.MaxRaysPerFrame then
		metrics.MaxRaysPerFrame = rays
	end
	if IS_STUDIO and rays == Config.Parkour.FrameRayBudget + 1 then
		local now = os.clock()
		if now - metrics.LastBudgetWarnAt >= Config.Parkour.BudgetWarnInterval then
			metrics.LastBudgetWarnAt = now
			warn(string.format(
				"[ParkourMetrics] %d+ raycasts in one frame (budget %d)",
				rays,
				Config.Parkour.FrameRayBudget
			))
		end
	end
end

function Metrics.snapshot(controller)
	local metrics = controller.Metrics
	local snapshot = table.clone(metrics.Stats)
	snapshot.RaysThisFrame = metrics.RaysThisFrame
	snapshot.MaxRaysPerFrame = metrics.MaxRaysPerFrame
	return snapshot
end

-- Clears the opt-in counters. MaxRaysPerFrame keeps the session maximum.
function Metrics.reset(controller)
	table.clear(controller.Metrics.Stats)
end

function Metrics.measure_search(controller, name, callback)
	if not Metrics.is_enabled(controller) then
		return callback(controller)
	end

	Metrics.reset(controller)
	local started_at = os.clock()
	local result = callback(controller)
	Metrics.record(controller, "SearchMilliseconds", (os.clock() - started_at) * 1000)

	local stats = Metrics.snapshot(controller)
	local values = {}
	for _, field in ipairs(REPORT_FIELDS) do
		table.insert(values, string.format("%s=%s", field, tostring(stats[field] or 0)))
	end
	print(string.format("[ParkourMetrics] %s %s", name, table.concat(values, " ")))
	return result
end

return Metrics
