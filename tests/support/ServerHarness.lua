--!strict
-- Builds the real Core composition (Telemetry, PlayerService, RemoteBudget)
-- over fakes: FakePlayers, a FakeClock scheduler and a recording analytics
-- sink. Specs add the services under test to `Runtime` before Start, then
-- drive players, characters and time through the fakes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Core = require(ServerScriptService.server.compose.Core)

local FakeClock = require(script.Parent.FakeClock)
local FakePlayers = require(script.Parent.FakePlayers)
local FakeRemote = require(script.Parent.FakeRemote)

local ServerHarness = {}
ServerHarness.__index = ServerHarness

export type CharacterOptions = {
	Name: string?,
	CFrame: CFrame?,
	RigType: Enum.HumanoidRigType?,
	Head: boolean?,
	Parent: Instance?,
}

function ServerHarness.new(): any
	local clock = FakeClock.new(100)
	local players = FakePlayers.new()
	local analytics = {
		Events = {} :: { { n: number, [number]: any } },
	}
	function analytics.LogCustomEvent(self: any, ...: any)
		table.insert(self.Events, table.pack(...))
	end

	local remotes = {
		Combat = FakeRemote.server(),
		Inventory = FakeRemote.server(),
		Weapon = FakeRemote.server(),
	}

	local runtime = Runtime.new("Spec")
	local env: any = {
		Players = players,
		Remotes = nil,
		WeaponModels = nil,
		IsStudio = false,
		Scheduler = clock:scheduler(),
		Heartbeat = nil,
		AnalyticsService = analytics,
	}
	Core(runtime, env)

	return setmetatable({
		Clock = clock,
		Players = players,
		Analytics = analytics,
		Remotes = remotes,
		Runtime = runtime,
		Created = {} :: { Instance },
	}, ServerHarness)
end

function ServerHarness.Start(self: any)
	self.Runtime:Start()
end

function ServerHarness.Get(self: any, name: string): any
	return self.Runtime:Get(name)
end

-- Tracks an instance so Destroy removes it.
function ServerHarness.Track(self: any, instance: Instance): Instance
	table.insert(self.Created, instance)
	return instance
end

-- A minimal live character in Workspace: HumanoidRootPart (2x2x1 anchored),
-- an R6 Humanoid and, unless Head = false, a Head above the root.
function ServerHarness.Character(self: any, opts: CharacterOptions?): (Model, Humanoid, BasePart)
	local options: CharacterOptions = opts or {}
	local cframe = options.CFrame or CFrame.new()

	local character = Instance.new("Model")
	character.Name = options.Name or "SpecCharacter"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CanCollide = false
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = cframe
	root.Parent = character
	character.PrimaryPart = root

	if options.Head ~= false then
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Anchored = true
		head.CanCollide = false
		head.Size = Vector3.new(1, 1, 1)
		head.CFrame = cframe * CFrame.new(0, 1.5, 0)
		head.Parent = character
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = options.RigType or Enum.HumanoidRigType.R6
	humanoid.Parent = character

	character.Parent = options.Parent or Workspace
	self:Track(character)

	return character, humanoid, root
end

function ServerHarness.Destroy(self: any)
	self.Runtime:Destroy()
	for index = #self.Created, 1, -1 do
		self.Created[index]:Destroy()
	end
	table.clear(self.Created)
end

return ServerHarness
