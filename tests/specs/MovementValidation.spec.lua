local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local MovementValidation = require(Services.MovementValidation)
local Limits = MovementValidation.Limits

local function create_character()
	local character = Instance.new("Model")
	character.Name = "MovementValidationCharacter"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.CanCollide = false
	root.Position = Vector3.zero
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	character.Parent = Workspace
	return character, root
end

-- Runs body with a temporary live character and always removes it.
local function with_character(body)
	local character, root = create_character()
	local ok, err = pcall(body, character, root)
	character:Destroy()
	if not ok then
		error(err, 0)
	end
end

local function create_state(character, position, now)
	local state = MovementValidation._create_state()
	state.Character = character
	state.FallStartY = position.Y
	state.LastDescentAt = now
	table.insert(state.Samples, {
		Position = position,
		Time = now,
		FallStartY = position.Y,
	})
	return state
end

return function()
	describe("Movement boundary validation", function()
		it("allows ordinary walk and sprint displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(2.4, 0, 0),
				0.1
			)).to.equal(nil)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(12, 0, 0),
				0.5
			)).to.equal(nil)
		end)

		it("allows scripted parkour-scale horizontal displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(13.5, 0, 0),
				0.2
			)).to.equal(nil)
		end)

		it("ignores large movement while a character is settling", function()
			with_character(function(character, root)
				local player = {}
				local now = os.clock()
				local state = create_state(character, Vector3.zero, now - 0.1)
				state.IgnoreUntil = now + 1

				local service = setmetatable({}, MovementValidation)
				root.Position = Vector3.new(0, 100, 0)
				service:_observe(player, state, now)

				expect(state.ViolationCount).to.equal(0)
				expect(state.LastReason).to.equal(nil)
				expect(#state.Samples).to.equal(1)
				expect(state.Samples[1].Position).to.equal(root.Position)
			end)
		end)

		it("averages a burst of delayed position updates over the sample window", function()
			with_character(function(character, root)
				local player = {}
				local start = os.clock()
				local state = create_state(character, Vector3.zero, start)
				local service = setmetatable({}, MovementValidation)

				-- The replicated position stalls for 0.3s, then catches up in a
				-- single frame. 24 studs in one frame is far beyond sprint speed,
				-- but over the covered 0.3s it is 80 studs/s.
				for step = 1, 18 do
					service:_observe(player, state, start + step / 60)
				end

				root.Position = Vector3.new(24, 0, 0)
				service:_observe(player, state, start + 0.3)

				expect(state.ViolationCount).to.equal(0)
				expect(state.LastReason).to.equal(nil)
			end)
		end)

		it("flags sustained implausible displacement across the window", function()
			with_character(function(character, root)
				local player = { Name = "MovementValidationPlayer", UserId = 0 }
				local start = os.clock()
				local state = create_state(character, Vector3.zero, start)
				local service = setmetatable({}, MovementValidation)

				-- 160 studs/s horizontally for 0.3s.
				for step = 1, 18 do
					root.Position = Vector3.new(160 * step / 60, 0, 0)
					service:_observe(player, state, start + step / 60)
				end

				expect(state.ViolationCount).to.equal(1)
				expect(state.LastReason).to.equal("HorizontalSpeed")
			end)
		end)

		it("keeps the fall height through a replication stall mid-fall", function()
			with_character(function(character, root)
				local player = { Name = "MovementValidationPlayer", UserId = 0 }
				local start = os.clock()
				local gravity = math.max(Workspace.Gravity, 0)
				-- Already falling from 600 studs above the window start.
				local state = create_state(character, Vector3.zero, start)
				state.FallStartY = 600
				state.Samples[1].FallStartY = 600
				local speed = math.sqrt(2 * gravity * 600)
				local service = setmetatable({}, MovementValidation)

				-- The replicated position stalls long enough to reset the fall
				-- apex, then catches up with the real free-fall displacement.
				local stall = Limits.FallResetDelay + 0.1
				for step = 1, math.floor(stall * 60) do
					service:_observe(player, state, start + step / 60)
				end

				local caught_up = start + stall + 1 / 60
				local elapsed = caught_up - start
				root.Position = Vector3.new(0, -(speed * elapsed + 0.5 * gravity * elapsed * elapsed), 0)
				service:_observe(player, state, caught_up)

				expect(state.ViolationCount).to.equal(0)
			end)
		end)

		it("does not judge a window shorter than the minimum span", function()
			with_character(function(character, root)
				local player = {}
				local start = os.clock()
				local state = create_state(character, Vector3.zero, start)
				local service = setmetatable({}, MovementValidation)

				root.Position = Vector3.new(30, 0, 0)
				service:_observe(player, state, start + Limits.MinWindowSpan / 2)

				expect(state.ViolationCount).to.equal(0)
			end)
		end)

		it("flags implausible horizontal displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(10, 0, 0),
				0.05
			)).to.equal("HorizontalSpeed")
		end)

		it("allows high downward physics velocity", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(0, -10, 0),
				0.05
			)).to.equal(nil)
		end)

		it("derives the downward bound from workspace gravity and fall height", function()
			local gravity = math.max(Workspace.Gravity, 0)
			local base = Limits.MaxDownwardSpeed
			local fall_height = 400

			expect(MovementValidation.GetMaxFallSpeed(0)).to.be.near(base)
			expect(MovementValidation.GetMaxFallSpeed(fall_height)).to.be.near(
				math.sqrt(base * base + 2 * gravity * fall_height)
			)
		end)

		it("allows long-fall speeds that exceed the flat downward cap", function()
			local fall_height = 400
			local delta_time = 0.1
			local fall_speed = MovementValidation.GetMaxFallSpeed(fall_height) * 0.9
			local displacement = Vector3.new(0, -fall_speed * delta_time, 0)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				displacement,
				delta_time,
				fall_height
			)).to.equal(nil)

			if fall_speed > Limits.MaxDownwardSpeed then
				expect(MovementValidation.ClassifyDelta(
					Vector3.zero,
					displacement,
					delta_time,
					0
				)).to.equal("VerticalSpeed")
			end
		end)

		it("keeps the upward bound independent of fall height", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(0, 13, 0),
				0.05,
				1000
			)).to.equal("VerticalSpeed")
		end)

		it("flags implausible vertical displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(0, 13, 0),
				0.05
			)).to.equal("VerticalSpeed")
		end)

		it("flags displacement far outside the envelope as a teleport", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(200, 0, 0),
				0.5
			)).to.equal("TeleportDistance")
		end)

		it("ignores samples with invalid or excessive time spans", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(1000, 0, 0),
				0
			)).to.equal(nil)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(1000, 0, 0),
				Limits.SampleWindow + 0.01
			)).to.equal(nil)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(1000, 0, 0),
				0.1,
				0 / 0
			)).to.equal(nil)
		end)
	end)
end
