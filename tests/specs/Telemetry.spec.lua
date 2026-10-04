--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Telemetry = require(ServerScriptService.server.services.Telemetry)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)
local FakeClock = require(TestService.support.FakeClock)

local CONFIG = {
	FlushInterval = 60,
	HalfLife = 10,
	DefaultWeight = 1,
	Weights = { Reach = 2, RateLimited = 0.5 },
}

local function make_analytics(): any
	local analytics = { Events = {} :: { any } }
	function analytics.LogCustomEvent(self: any, player: any, name: string, value: number?, fields: { [string]: string }?)
		table.insert(self.Events, { Player = player, Name = name, Value = value, Fields = fields })
	end
	return analytics
end

local function make(clock: any, analytics: any?): any
	return Telemetry.new({
		config = CONFIG,
		scheduler = clock:scheduler(),
		analytics = analytics,
		is_studio = false,
	})
end

return function()
	describe("Telemetry", function()
		it("aggregates counts by category, reason and detail", function()
			local clock = FakeClock.new()
			local telemetry = make(clock)
			local first = { Parent = true }
			local second = { Parent = true }

			telemetry:Count(first, "Combat", "Reach", "Katana")
			telemetry:Count(second, "Combat", "Reach", "Katana")
			telemetry:Count(first, "Combat", "Reach", "Fists")
			telemetry:Count(nil, "Lifecycle", "ComponentFailed")

			local snapshot = telemetry:Snapshot()
			expect(snapshot["Combat.Reach.Katana"]).to.equal(2)
			expect(snapshot["Combat.Reach.Fists"]).to.equal(1)
			expect(snapshot["Lifecycle.ComponentFailed.-"]).to.equal(1)
			telemetry:Destroy()
		end)

		it("decays suspicion with the configured half-life", function()
			local clock = FakeClock.new()
			local telemetry = make(clock)
			local player = { Parent = true }

			telemetry:Count(player, "Combat", "Reach", "Katana")
			telemetry:Count(player, "Network", "RateLimited", "Combat.Hit")
			telemetry:Count(player, "Movement", "Unweighted")
			expect(telemetry:GetSuspicion(player)).to.be.near(2 + 0.5 + 1)

			clock:advance(10)
			expect(telemetry:GetSuspicion(player)).to.be.near(3.5 / 2)

			clock:advance(10)
			telemetry:Count(player, "Combat", "Reach", "Katana")
			expect(telemetry:GetSuspicion(player)).to.be.near(3.5 / 4 + 2)
			telemetry:Destroy()
		end)

		it("does not add suspicion for server-side categories", function()
			local clock = FakeClock.new()
			local telemetry = make(clock)
			local player = { Parent = true }

			telemetry:Count(player, "Lifecycle", "ComponentFailed", "Inventory")
			telemetry:Count(player, "Data", "LoadFailed")

			expect(telemetry:GetSuspicion(player)).to.equal(0)
			telemetry:Destroy()
		end)

		it("flushes one event per counter on the flush interval and resets counts", function()
			local clock = FakeClock.new()
			local analytics = make_analytics()
			local telemetry = make(clock, analytics)
			local player = { Parent = true }
			telemetry:Start()

			telemetry:Count(player, "Combat", "NoLOS", "Katana")
			telemetry:Count(player, "Combat", "NoLOS", "Katana")
			telemetry:Count(player, "Network", "RateLimited", "Combat.Hit")
			telemetry:Count(nil, "Lifecycle", "ComponentFailed", "X")

			clock:advance(CONFIG.FlushInterval - 1)
			expect(#analytics.Events).to.equal(0)

			clock:advance(1)
			expect(#analytics.Events).to.equal(2)

			local by_name = {}
			for _, event in analytics.Events do
				by_name[event.Name] = event
				expect(event.Player).to.equal(player)
			end
			expect(by_name.Reject_Combat.Value).to.equal(2)
			expect(by_name.Reject_Combat.Fields.CustomField01).to.equal("NoLOS")
			expect(by_name.Reject_Combat.Fields.CustomField02).to.equal("Katana")
			expect(by_name.Reject_Network.Fields.CustomField02).to.equal("Combat.Hit")
			expect((next(telemetry:Snapshot()))).to.equal(nil)

			-- The flush reschedules itself.
			telemetry:Count(player, "Combat", "Reach", "Fists")
			clock:advance(CONFIG.FlushInterval)
			expect(#analytics.Events).to.equal(3)

			telemetry:Destroy()
			expect(clock:pending()).to.equal(0)
		end)

		it("survives an analytics sink that errors", function()
			local clock = FakeClock.new()
			local analytics = {
				LogCustomEvent = function()
					error("analytics down", 0)
				end,
			}
			local telemetry = make(clock, analytics)

			telemetry:Count({ Parent = true }, "Combat", "Reach", "Katana")

			expect(function()
				telemetry:Flush()
			end).never.to.throw()
			telemetry:Destroy()
		end)

		it("logs a leaving player's counts at Forget and keeps them in the totals", function()
			local clock = FakeClock.new()
			local analytics = make_analytics()
			local telemetry = make(clock, analytics)
			local player = { Parent = true }

			telemetry:Count(player, "Combat", "Facing", "Katana")
			telemetry:Forget(player)

			expect(#analytics.Events).to.equal(1)
			expect(telemetry:GetSuspicion(player)).to.equal(0)
			expect(telemetry:Snapshot()["Combat.Facing.Katana"]).to.equal(1)

			-- Server-held totals are not logged again against a player.
			telemetry:Flush()
			expect(#analytics.Events).to.equal(1)
			telemetry:Destroy()
		end)

		it("bounds the number of distinct details per player", function()
			local clock = FakeClock.new()
			local telemetry = make(clock)
			local player = { Parent = true }

			for index = 1, 200 do
				telemetry:Count(player, "Network", "UnknownAction", "Action" .. index)
			end
			telemetry:Count(player, "Network", "UnknownAction", string.rep("x", 10000))

			local keys = 0
			local total = 0
			for key, count in telemetry:Snapshot() do
				keys += 1
				total += count
				expect(#key < 200).to.equal(true)
			end
			expect(keys <= 65).to.equal(true)
			expect(total).to.equal(201)
			telemetry:Destroy()
		end)

		it("rejects unknown categories", function()
			local telemetry = make(FakeClock.new())

			expect(function()
				telemetry:Count(nil, "Nope" :: any, "Reach")
			end).to.throw()
			telemetry:Destroy()
		end)
	end)

	describe("RejectReason", function()
		it("maps every reason to itself and recognises only listed reasons", function()
			for _, name in RejectReason.All do
				expect((RejectReason :: any)[name]).to.equal(name)
				expect(RejectReason.is(name)).to.equal(true)
			end

			expect(RejectReason.is("Nope")).to.equal(false)
			expect(RejectReason.is(nil)).to.equal(false)
			expect(RejectReason.is("is")).to.equal(false)
			expect(table.isfrozen(RejectReason)).to.equal(true)
		end)
	end)
end
