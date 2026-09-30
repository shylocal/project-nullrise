-- Opt-in parkour query counters for Studio profiling. Disabled by default.
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

function Metrics.is_enabled(controller)
	return controller._queryMetricsEnabled == true
end

function Metrics.record(controller, name, amount)
	if not Metrics.is_enabled(controller) then
		return
	end

	local stats = controller._queryMetrics
	if not stats then
		stats = {}
		controller._queryMetrics = stats
	end
	stats[name] = (stats[name] or 0) + (amount or 1)
end

function Metrics.snapshot(controller)
	return table.clone(controller._queryMetrics or {})
end

function Metrics.reset(controller)
	local stats = controller._queryMetrics
	if not stats then
		stats = {}
		controller._queryMetrics = stats
	else
		table.clear(stats)
	end
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
