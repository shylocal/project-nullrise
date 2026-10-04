--!strict
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local RemoteBudget = require(ServerScriptService.server.network.RemoteBudget)
local ServerHarness = require(TestService.support.ServerHarness)

local CONFIG = {
	Global = { Rate = 10, Burst = 5 },
	Actions = {
		Fast = { Rate = 10, Burst = 3 },
		Slow = { Rate = 1, Burst = 1 },
		-- Larger than the global bucket, so only the global bucket limits it.
		Wide = { Rate = 100, Burst = 10 },
	},
}

-- Builds a second budget with CONFIG next to the harness's own (real config)
-- budget, so these specs do not depend on tuning values.
local function setup(): (any, any)
	local h = ServerHarness.new()
	h.Runtime:Add("SpecBudget", function(get)
		return RemoteBudget.new({
			players = get("PlayerService"),
			config = CONFIG,
			clock = h.Clock.now,
			telemetry = get("Telemetry"),
		})
	end)
	h:Start()
	return h, h:Get("SpecBudget")
end

local function take_many(budget: any, player: any, action: string, count: number): number
	local granted = 0
	for _ = 1, count do
		if budget:Take(player, action) then
			granted += 1
		end
	end
	return granted
end

return function()
	describe("RemoteBudget", function()
		local h: any
		local budget: any

		beforeEach(function()
			h, budget = setup()
		end)

		afterEach(function()
			h:Destroy()
		end)

		it("grants up to Burst, then refills at Rate", function()
			local player = h.Players:Add()

			expect(take_many(budget, player, "Fast", 10)).to.equal(3)

			h.Clock:advance(0.125)
			expect(take_many(budget, player, "Fast", 10)).to.equal(1)

			h.Clock:advance(10)
			expect(take_many(budget, player, "Fast", 10)).to.equal(3)
		end)

		it("counts denied takes as RateLimited with the action", function()
			local player = h.Players:Add()
			local telemetry = h:Get("Telemetry")

			take_many(budget, player, "Slow", 3)

			expect(telemetry:Snapshot()["Network.RateLimited.Slow"]).to.equal(2)
		end)

		it("keeps action buckets independent", function()
			local player = h.Players:Add()

			expect(take_many(budget, player, "Slow", 2)).to.equal(1)
			-- Slow being empty does not affect Fast.
			expect(take_many(budget, player, "Fast", 5)).to.equal(3)
		end)

		it("denies every action once the shared global bucket is empty", function()
			local player = h.Players:Add()

			-- Wide has 10 tokens but the global bucket only 5.
			expect(take_many(budget, player, "Wide", 10)).to.equal(5)
			expect(take_many(budget, player, "Fast", 1)).to.equal(0)

			-- 0.125s refills 1.25 global tokens.
			h.Clock:advance(0.125)
			expect(take_many(budget, player, "Fast", 3)).to.equal(1)
		end)

		it("rejects unknown actions, spends a global token and counts them", function()
			local player = h.Players:Add()
			local telemetry = h:Get("Telemetry")

			expect(budget:Take(player, "Nope")).to.equal(false)
			expect(telemetry:Snapshot()["Network.UnknownAction.Nope"]).to.equal(1)

			-- 4 unknown requests drain the rest of the 5-token global bucket.
			take_many(budget, player, "Nope", 4)
			expect(budget:Take(player, "Fast")).to.equal(false)
		end)

		it("keeps separate buckets per player", function()
			local first = h.Players:Add()
			local second = h.Players:Add()

			expect(take_many(budget, first, "Slow", 2)).to.equal(1)
			expect(take_many(budget, second, "Slow", 2)).to.equal(1)
		end)

		it("does not reset on respawn", function()
			local player = h.Players:Add()
			player:SetCharacter(h:Character())

			expect(take_many(budget, player, "Slow", 1)).to.equal(1)
			player:SetCharacter(h:Character())
			expect(take_many(budget, player, "Slow", 1)).to.equal(0)
		end)

		it("returns false without a session", function()
			expect(budget:Take({}, "Fast")).to.equal(false)

			local player = h.Players:Add()
			h.Players:Remove(player)
			expect(budget:Take(player, "Fast")).to.equal(false)
		end)

		it("rejects invalid configuration", function()
			expect(function()
				RemoteBudget.new({
					players = h:Get("PlayerService"),
					config = { Global = { Rate = 0, Burst = 1 }, Actions = {} },
					clock = h.Clock.now,
					telemetry = h:Get("Telemetry"),
				})
			end).to.throw()
		end)
	end)
end
