--!strict
-- Combat and movement validation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local Envelope = require(ReplicatedStorage.shared.config.Envelope)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)

local server = script.Parent.Parent
local Core = require(server.compose.Core)
local CombatService = require(server.services.CombatService)
local MovementValidation = require(server.services.MovementValidation)

return function(rt: Runtime.Runtime, env: Core.ServerEnv): ()
	rt:Add("CombatService", function(get)
		return CombatService.new({
			players = get("PlayerService"),
			weapons = get("WeaponService"),
			remote = env.Remotes:FindFirstChild("Combat"),
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
			scheduler = env.Scheduler,
		})
	end)

	rt:Add("MovementValidation", function(get)
		return MovementValidation.new({
			players = get("PlayerService"),
			telemetry = get("Telemetry"),
			scheduler = env.Scheduler,
			step = env.Heartbeat,
			-- Gravity is sampled once here; a runtime change does not move the limits.
			limits = Envelope.compute(Config.Movement, Config.Parkour, Workspace.Gravity),
		})
	end)
end
