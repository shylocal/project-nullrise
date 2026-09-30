local StarterPlayer = game:GetService("StarterPlayer")
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local Metrics = require(Client.controllers.ParkourController.Metrics)

return function()
	describe("Parkour query metrics", function()
	local controller

	beforeEach(function()
		controller = {
			_queryMetricsEnabled = false,
			_queryMetrics = {},
		}
	end)

	it("does not collect profiling counters unless enabled", function()
		Metrics.record(controller, "Raycasts")
		expect(Metrics.snapshot(controller).Raycasts).to.equal(nil)
	end)

	it("collects, snapshots, and resets opt-in counters", function()
		controller._queryMetricsEnabled = true
		Metrics.record(controller, "Raycasts")
		Metrics.record(controller, "Raycasts", 4)
		Metrics.record(controller, "GuideColumns", 42)
		Metrics.record(controller, "ModelBoundsQueries", 3)

		local snapshot = Metrics.snapshot(controller)
		expect(snapshot.Raycasts).to.equal(5)
		expect(snapshot.GuideColumns).to.equal(42)
		expect(snapshot.ModelBoundsQueries).to.equal(3)
		snapshot.Raycasts = 100
		expect(Metrics.snapshot(controller).Raycasts).to.equal(5)

		Metrics.reset(controller)
		expect(Metrics.snapshot(controller).Raycasts).to.equal(nil)
		expect(Metrics.snapshot(controller).GuideColumns).to.equal(nil)
		expect(Metrics.snapshot(controller).ModelBoundsQueries).to.equal(nil)
	end)
	end)
end
