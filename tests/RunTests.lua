-- Manual TestEZ entrypoint. This ModuleScript never runs automatically.
local RunService = game:GetService("RunService")

-- TestEZ is vendored beside this module (tests/TestEZ -> TestService.TestEZ)
-- so the test runner is never shipped to clients.
local TestEZ = require(script.Parent.TestEZ)

local RunTests = {}

function RunTests.Run()
	assert(RunService:IsStudio(), "TestEZ may only be run in Roblox Studio.")

	local specs = script.Parent:FindFirstChild("specs")
	assert(specs, "TestEZ spec folder is missing.")

	return TestEZ.TestBootstrap:run({ specs }, TestEZ.Reporters.TextReporter)
end

return RunTests
