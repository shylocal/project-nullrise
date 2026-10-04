--!strict
-- Core server services: Telemetry, then PlayerService (which reports
-- component failures to Telemetry), then RemoteBudget (the first component).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.shared.config)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local server = script.Parent.Parent
local Telemetry = require(server.services.Telemetry)
local PlayerService = require(server.services.PlayerService)
local RemoteBudget = require(server.network.RemoteBudget)

-- Everything composition reads from the engine, gathered by init.server.lua
-- so compose modules stay free of direct service lookups.
export type ServerEnv = {
	Players: Players,
	Remotes: Folder,
	WeaponModels: Instance?,
	IsStudio: boolean,
	Scheduler: Scheduler.Scheduler,
	Heartbeat: RBXScriptSignal,
	AnalyticsService: AnalyticsService,
}

return function(rt: Runtime.Runtime, env: ServerEnv): ()
	rt:Add("Telemetry", function()
		return Telemetry.new({
			config = Config.Telemetry,
			scheduler = env.Scheduler,
			-- Engine boundary: AnalyticsService satisfies AnalyticsLike.
			analytics = env.AnalyticsService :: any,
			is_studio = env.IsStudio,
		})
	end)

	rt:Add("PlayerService", function(get)
		return PlayerService.new({
			players = env.Players,
			telemetry = get("Telemetry"),
		})
	end)

	rt:Add("RemoteBudget", function(get)
		return RemoteBudget.new({
			players = get("PlayerService"),
			config = Config.Network.RemoteBudget,
			clock = env.Scheduler.clock,
			telemetry = get("Telemetry"),
		})
	end)
end
