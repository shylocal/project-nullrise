-- Manual TestEZ entrypoint. This ModuleScript never runs automatically.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TestEZ = require(ReplicatedStorage.packages.TestEZ)

local RunTests = {}

function RunTests.Run()
	assert(RunService:IsStudio(), "TestEZ may only be run in Roblox Studio.")

	local specs = script.Parent:FindFirstChild("specs")
	assert(specs, "TestEZ spec folder is missing.")

	return TestEZ.TestBootstrap:run({ specs }, TestEZ.Reporters.TextReporter)
end

return RunTests
