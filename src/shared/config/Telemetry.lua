--!strict
local Telemetry = {
	-- Seconds between AnalyticsService flushes.
	FlushInterval = 60,
	-- Seconds for a player's suspicion score to decay by half.
	HalfLife = 60,
	-- Suspicion weight of any reason not listed in Weights. This is the
	-- documented default for unweighted reasons, not a fallback for bad data.
	DefaultWeight = 1,
	Weights = {
		BadPayload = 2,
		RateLimited = 0.25,
		TeleportDistance = 3,
		Reach = 1,
		OffBody = 1,
		HitpointOffset = 1,
		Facing = 1,
		NoLOS = 1,
		HorizontalSpeed = 1,
		VerticalSpeed = 1,
	},
}

export type TelemetryConfig = { FlushInterval: number, HalfLife: number, DefaultWeight: number, Weights: { [string]: number } }

return Telemetry :: TelemetryConfig
