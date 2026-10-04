--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.packages.Signal)
local MovementValidation = require(ServerScriptService.server.services.MovementValidation)
local PositionHistory = require(ServerScriptService.server.services.PositionHistory)
local ServerHarness = require(TestService.support.ServerHarness)

local Window = MovementValidation.Window

-- The pre-envelope limits, so these expectations stay independent of tuning.
local LIMITS = {
	MaxHorizontalSpeed = 96,
	MaxUpwardSpeed = 240,
	MaxDownwardSpeed = 240,
	TeleportDistance = 40,
	Sources = {},
}

local FRAME = 1 / 60

type Fixture = {
	h: any,
	step: any,
	service: any,
	player: any,
	root: BasePart,
}

local function setup(limits: any?): Fixture
	local h = ServerHarness.new()
	local step = Signal.new()
	-- Samples come from a real PositionHistory driven by `step`.
	h.Runtime:Add("PositionHistory", function(get)
		return PositionHistory.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			step = step,
			capacity = 64,
		})
	end)
	h.Runtime:Add("MovementValidation", function(get)
		return MovementValidation.new({
			players = get("PlayerService"),
			telemetry = get("Telemetry"),
			scheduler = h.Clock:scheduler(),
			history = get("PositionHistory"),
			limits = limits or LIMITS,
		})
	end)
	h:Start()

	local player = h.Players:Add({ Name = "MovementValidationPlayer" })
	local character, _, root = h:Character()
	player:SetCharacter(character)

	return {
		h = h,
		step = step,
		service = h:Get("MovementValidation"),
		player = player,
		root = root,
	}
end

local function tick(f: Fixture, dt: number)
	f.h.Clock:advance(dt)
	f.step:Fire()
end

local function state_of(f: Fixture): any
	return f.h:Get("PlayerService"):Get(f.player):Get(f.service)
end

-- Steps frames until the spawn grace period is over.
local function settle(f: Fixture)
	local state = state_of(f)
	while f.h.Clock.now() < state.IgnoreUntil do
		tick(f, FRAME)
	end
end

local function violations(f: Fixture): number
	return f.service:GetReport(f.player).ViolationCount
end

local function classify(previous: Vector3, current: Vector3, dt: number, fall_height: number?): string?
	return MovementValidation.ClassifyDelta(previous, current, dt, fall_height, LIMITS)
end

return function()
	describe("MovementValidation.ClassifyDelta", function()
		it("allows ordinary walk and sprint displacement", function()
			expect(classify(Vector3.zero, Vector3.new(2.4, 0, 0), 0.1)).to.equal(nil)
			expect(classify(Vector3.zero, Vector3.new(12, 0, 0), 0.5)).to.equal(nil)
		end)

		it("allows scripted parkour-scale horizontal displacement", function()
			expect(classify(Vector3.zero, Vector3.new(13.5, 0, 0), 0.2)).to.equal(nil)
		end)

		it("flags implausible horizontal displacement", function()
			expect(classify(Vector3.zero, Vector3.new(10, 0, 0), 0.05)).to.equal("HorizontalSpeed")
		end)

		it("allows high downward physics velocity", function()
			expect(classify(Vector3.zero, Vector3.new(0, -10, 0), 0.05)).to.equal(nil)
		end)

		it("derives the downward bound from workspace gravity and fall height", function()
			local gravity = math.max(Workspace.Gravity, 0)
			local base = LIMITS.MaxDownwardSpeed

			expect(MovementValidation.GetMaxFallSpeed(0, LIMITS)).to.be.near(base)
			expect(MovementValidation.GetMaxFallSpeed(400, LIMITS)).to.be.near(math.sqrt(base * base + 2 * gravity * 400))
		end)

		it("allows long-fall speeds that exceed the flat downward cap", function()
			local fall_height = 400
			local delta_time = 0.1
			local fall_speed = MovementValidation.GetMaxFallSpeed(fall_height, LIMITS) * 0.9
			local displacement = Vector3.new(0, -fall_speed * delta_time, 0)

			expect(classify(Vector3.zero, displacement, delta_time, fall_height)).to.equal(nil)

			if fall_speed > LIMITS.MaxDownwardSpeed then
				expect(classify(Vector3.zero, displacement, delta_time, 0)).to.equal("VerticalSpeed")
			end
		end)

		it("keeps the upward bound independent of fall height", function()
			expect(classify(Vector3.zero, Vector3.new(0, 13, 0), 0.05, 1000)).to.equal("VerticalSpeed")
		end)

		it("flags implausible vertical displacement", function()
			expect(classify(Vector3.zero, Vector3.new(0, 13, 0), 0.05)).to.equal("VerticalSpeed")
		end)

		it("flags displacement far outside the envelope as a teleport", function()
			expect(classify(Vector3.zero, Vector3.new(200, 0, 0), 0.5)).to.equal("TeleportDistance")
		end)

		it("ignores samples with invalid or excessive time spans", function()
			expect(classify(Vector3.zero, Vector3.new(1000, 0, 0), 0)).to.equal(nil)
			expect(classify(Vector3.zero, Vector3.new(1000, 0, 0), Window.SampleWindow + 0.01)).to.equal(nil)
			expect(classify(Vector3.zero, Vector3.new(1000, 0, 0), 0.1, 0 / 0)).to.equal(nil)
		end)

		it("judges against the limits it is given", function()
			local tight = table.clone(LIMITS)
			tight.MaxHorizontalSpeed = 10

			expect(MovementValidation.ClassifyDelta(Vector3.zero, Vector3.new(4, 0, 0), 0.25, 0, tight)).to.equal(
				"HorizontalSpeed"
			)
			expect(MovementValidation.ClassifyDelta(Vector3.zero, Vector3.new(4, 0, 0), 0.25, 0, LIMITS)).to.equal(nil)
		end)
	end)

	describe("MovementValidation observation", function()
		local f: Fixture

		afterEach(function()
			f.h:Destroy()
		end)

		it("ignores large movement while a character is settling", function()
			f = setup()
			tick(f, 0.1)
			f.root.Position = Vector3.new(0, 100, 0)
			tick(f, FRAME)

			expect(violations(f)).to.equal(0)
			expect(f.service:GetReport(f.player).LastReason).to.equal(nil)
		end)

		it("averages a burst of delayed position updates over the sample window", function()
			f = setup()
			settle(f)

			-- The replicated position stalls for 0.3s, then catches up in a
			-- single frame. 24 studs in one frame is far beyond sprint speed,
			-- but over the covered 0.3s it is 80 studs/s.
			for _ = 1, 17 do
				tick(f, FRAME)
			end
			f.root.Position = Vector3.new(24, 0, 0)
			tick(f, FRAME)

			expect(violations(f)).to.equal(0)
		end)

		it("flags sustained implausible displacement across the window once", function()
			f = setup()
			settle(f)

			-- 160 studs/s horizontally for 0.3s.
			for frame = 1, 18 do
				f.root.Position = Vector3.new(160 * frame * FRAME, 0, 0)
				tick(f, FRAME)
			end

			expect(violations(f)).to.equal(1)
			expect(f.service:GetReport(f.player).LastReason).to.equal("HorizontalSpeed")
			expect(f.h:Get("Telemetry"):Snapshot()["Movement.HorizontalSpeed.-"]).to.equal(1)
		end)

		it("uses the limits it was constructed with", function()
			local tight = table.clone(LIMITS)
			tight.MaxHorizontalSpeed = 10
			f = setup(tight)
			settle(f)

			-- 20 studs/s: walking pace, but above this instance's limit.
			for frame = 1, 30 do
				f.root.Position = Vector3.new(20 * frame * FRAME, 0, 0)
				tick(f, FRAME)
			end

			expect(violations(f) >= 1).to.equal(true)
		end)

		it("keeps the fall height through a replication stall mid-fall", function()
			f = setup()
			local start_y = 600
			f.root.Position = Vector3.new(0, start_y, 0)
			-- Re-spawn at the new height so tracking starts there.
			local character = f.root.Parent :: Model
			f.player:SetCharacter(nil)
			f.player:SetCharacter(character)
			settle(f)

			local gravity = math.max(Workspace.Gravity, 0)
			local elapsed = 0
			local function fall_y(t: number): number
				return start_y - 0.5 * gravity * t * t
			end

			-- Free fall for 1.5s, observed every frame.
			for _ = 1, 90 do
				elapsed += FRAME
				f.root.Position = Vector3.new(0, fall_y(elapsed), 0)
				tick(f, FRAME)
			end

			-- The replicated position stalls long enough to reset the fall
			-- apex, then catches up with the real free-fall displacement.
			local stall_frames = math.ceil((Window.FallResetDelay + 0.1) / FRAME)
			for _ = 1, stall_frames do
				elapsed += FRAME
				tick(f, FRAME)
			end
			f.root.Position = Vector3.new(0, fall_y(elapsed), 0)
			tick(f, 0)

			expect(violations(f)).to.equal(0)
		end)

		it("does not judge a window shorter than the minimum span", function()
			f = setup()
			settle(f)

			f.root.Position = Vector3.new(30, 0, 0)
			tick(f, Window.MinWindowSpan / 2)

			expect(violations(f)).to.equal(0)
		end)

		it("resets its report and grace period on respawn", function()
			f = setup()
			settle(f)
			for frame = 1, 18 do
				f.root.Position = Vector3.new(160 * frame * FRAME, 0, 0)
				tick(f, FRAME)
			end
			expect(violations(f)).to.equal(1)

			local character = f.h:Character()
			f.player:SetCharacter(character)

			expect(violations(f)).to.equal(0)
		end)

		it("treats a dead character as having no position", function()
			f = setup()
			settle(f)
			local humanoid = (f.root.Parent :: Model):FindFirstChildOfClass("Humanoid") :: Humanoid
			humanoid.Health = 0
			f.root.Position = Vector3.new(500, 0, 0)
			tick(f, FRAME)

			expect(violations(f)).to.equal(0)
			expect(#state_of(f).Samples).to.equal(0)
		end)

		it("forgets the player when they leave", function()
			f = setup()
			f.h.Players:Remove(f.player)

			expect(f.service:GetReport(f.player)).to.equal(nil)
		end)
	end)
end
