--!strict
-- Combat and movement validation: position history (lag compensation and the
-- movement observer's sample source), movement validation, damage, hit
-- effects, then combat itself.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local Envelope = require(ReplicatedStorage.shared.config.Envelope)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)

local server = script.Parent.Parent
local Core = require(server.compose.Core)
local CombatFxService = require(server.services.CombatFxService)
local CombatService = require(server.services.CombatService)
local DamageService = require(server.services.DamageService)
local MovementValidation = require(server.services.MovementValidation)
local PositionHistory = require(server.services.PositionHistory)

return function(rt: Runtime.Runtime, env: Core.ServerEnv): ()
	rt:Add("PositionHistory", function(get)
		return PositionHistory.new({
			players = get("PlayerService"),
			scheduler = env.Scheduler,
			step = env.Heartbeat,
			capacity = Config.Combat.LagCompensation.HistoryCapacity,
		})
	end)

	rt:Add("MovementValidation", function(get)
		return MovementValidation.new({
			players = get("PlayerService"),
			telemetry = get("Telemetry"),
			scheduler = env.Scheduler,
			history = get("PositionHistory"),
			-- Gravity is sampled once here; a runtime change does not move the limits.
			limits = Envelope.compute(Config.Movement, Config.Parkour, Workspace.Gravity),
		})
	end)

	rt:Add("DamageService", function(get)
		return DamageService.new({
			players = get("PlayerService"),
			scheduler = env.Scheduler,
			config = Config.Combat.Damage,
			tags = Config.World.Tags,
		})
	end)

	rt:Add("CombatFxService", function(get)
		return CombatFxService.new({
			damage = get("DamageService"),
			players = get("PlayerService"),
			-- Engine boundary: UnreliableRemoteEvent satisfies UnreliableRemoteLike.
			remote = env.Remotes:FindFirstChild("CombatFx") :: any,
			config = Config.Combat.Fx,
		})
	end)

	rt:Add("CombatService", function(get)
		return CombatService.new({
			players = get("PlayerService"),
			weapons = get("WeaponService"),
			remote = env.Remotes:FindFirstChild("Combat"),
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
			scheduler = env.Scheduler,
			damage = get("DamageService"),
			history = get("PositionHistory"),
		})
	end)
end
