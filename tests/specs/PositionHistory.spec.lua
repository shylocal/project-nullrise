--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Signal = require(ReplicatedStorage.packages.Signal)
local PositionHistory = require(ServerScriptService.server.services.PositionHistory)
local ServerHarness = require(TestService.support.ServerHarness)

type Fixture = {
	h: any,
	step: any,
	history: any,
	player: any,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
}

local function setup(capacity: number?): Fixture
	local h = ServerHarness.new()
	local step = Signal.new()
	h.Runtime:Add("PositionHistory", function(get)
		return PositionHistory.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			step = step,
			capacity = capacity or 8,
		})
	end)
	h:Start()

	local player = h.Players:Add()
	local character, humanoid, root = h:Character()
	player:SetCharacter(character)

	return {
		h = h,
		step = step,
		history = h:Get("PositionHistory"),
		player = player,
		character = character,
		humanoid = humanoid,
		root = root,
	}
end

-- Moves the root to x, then advances the clock by dt and steps.
local function record(f: Fixture, x: number, dt: number)
	f.root.CFrame = CFrame.new(x, 0, 0)
	f.h.Clock:advance(dt)
	f.step:Fire()
end

return function()
	describe("PositionHistory", function()
		local f: Fixture

		afterEach(function()
			f.h:Destroy()
		end)

		it("requires its dependencies and a usable capacity", function()
			f = setup()
			expect(function()
				PositionHistory.new({} :: any)
			end).to.throw()
			expect(function()
				PositionHistory.new({
					players = f.h:Get("PlayerService"),
					scheduler = f.h.Clock:scheduler(),
					step = Signal.new(),
					capacity = 1,
				})
			end).to.throw()
		end)

		it("records one sample per step and fires Stepped after writing", function()
			f = setup()
			local seen: { number } = {}
			f.history.Stepped:Connect(function(now: number)
				local latest = f.history:Latest(f.character)
				expect(latest.Time).to.equal(now)
				table.insert(seen, now)
			end)

			record(f, 5, 0.1)

			local latest = f.history:Latest(f.character)
			expect(latest).to.be.ok()
			expect(latest.RootCFrame.Position.X).to.be.near(5)
			expect(latest.BoxSize.Magnitude > 0).to.equal(true)
			expect(#seen).to.equal(1)
			expect(seen[1]).to.equal(f.h.Clock.now())
		end)

		it("interpolates between samples and clamps outside the recorded range", function()
			f = setup()
			record(f, 0, 0.1)
			local first = f.h.Clock.now()
			record(f, 10, 0.1)
			local second = f.h.Clock.now()

			local middle = f.history:Sample(f.character, (first + second) / 2)
			expect(middle.RootCFrame.Position.X).to.be.near(5)
			expect(f.history:Sample(f.character, first - 5).RootCFrame.Position.X).to.be.near(0)
			expect(f.history:Sample(f.character, second + 5).RootCFrame.Position.X).to.be.near(10)
		end)

		it("keeps only the newest Capacity samples", function()
			f = setup(4)
			for x = 1, 6 do
				record(f, x, 0.1)
			end

			-- The oldest kept sample is x = 3.
			expect(f.history:Sample(f.character, 0).RootCFrame.Position.X).to.be.near(3)
			expect(f.history:Latest(f.character).RootCFrame.Position.X).to.be.near(6)
		end)

		it("does not write samples for a dead character", function()
			f = setup()
			record(f, 1, 0.1)
			local before = f.history:Latest(f.character)

			f.humanoid.Health = 0
			record(f, 2, 0.1)

			expect(f.history:Latest(f.character)).to.equal(before)
		end)

		it("stops tracking a removed character and tracks the new one", function()
			f = setup()
			record(f, 1, 0.1)
			local old = f.character

			local replacement = f.h:Character({ Name = "Respawned" })
			f.player:SetCharacter(replacement)
			f.h.Clock:advance(0.1)
			f.step:Fire()

			expect(f.history:Latest(old)).to.equal(nil)
			expect(f.history:Latest(replacement)).to.be.ok()
		end)

		it("returns nothing for untracked models", function()
			f = setup()
			local stranger = f.h:Character({ Name = "Stranger" })
			f.step:Fire()

			expect(f.history:Latest(stranger)).to.equal(nil)
			expect(f.history:Sample(stranger, 0)).to.equal(nil)
		end)
	end)
end
