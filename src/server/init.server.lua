-- Server entry point: gathers the engine environment, composes every service
-- through one Runtime (ordered construction and Start, reverse teardown) and
-- tears it all down when this script is destroyed.
local AnalyticsService = game:GetService("AnalyticsService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.shared.config)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local Content = require(script.compose.Content)
local Core = require(script.compose.Core)
local Items = require(script.compose.Items)
local Combat = require(script.compose.Combat)

local CLIMBABLE_COLLISION_GROUP = Config.World.CollisionGroups.Climbable

if not PhysicsService:IsCollisionGroupRegistered(CLIMBABLE_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(CLIMBABLE_COLLISION_GROUP)
end

local env: Core.ServerEnv = {
	Players = Players,
	Remotes = ReplicatedStorage:FindFirstChild(Config.World.Folders.Remotes) :: Folder,
	WeaponModels = ServerStorage:FindFirstChild(Config.World.Folders.WeaponModels),
	IsStudio = RunService:IsStudio(),
	Scheduler = Scheduler.real(),
	Heartbeat = RunService.Heartbeat,
	AnalyticsService = AnalyticsService,
}

assert(env.Remotes, ("ReplicatedStorage.%s is missing"):format(Config.World.Folders.Remotes))

local runtime = Runtime.new("Server")
-- Content first: assets are verified before any service is built.
Content(runtime, env)
Core(runtime, env)
Items(runtime, env)
Combat(runtime, env)
runtime:Start()

script.Destroying:Connect(function()
	runtime:Destroy()
end)
