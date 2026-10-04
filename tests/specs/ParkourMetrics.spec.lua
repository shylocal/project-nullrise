--!strict
local StarterPlayer = game:GetService("StarterPlayer")
local Metrics = require(StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController.Metrics)

return function()
	describe("Parkour query metrics", function()
	local controller

	beforeEach(function()
		controller = {
			Metrics = Metrics.new(false),
		}
	end)

	it("does not collect profiling counters unless enabled", function()
		Metrics.record(controller, "Raycasts")
		expect(Metrics.snapshot(controller).Raycasts).to.equal(nil)
	end)

	it("collects, snapshots, and resets opt-in counters", function()
		Metrics.set_enabled(controller, true)
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

	it("counts rays per frame even when profiling is disabled", function()
		Metrics.begin_frame(controller)
		Metrics.count_ray(controller)
		Metrics.count_ray(controller)
		Metrics.count_ray(controller)
		expect(Metrics.snapshot(controller).RaysThisFrame).to.equal(3)
		expect(Metrics.snapshot(controller).MaxRaysPerFrame).to.equal(3)

		Metrics.begin_frame(controller)
		Metrics.count_ray(controller)
		local snapshot = Metrics.snapshot(controller)
		expect(snapshot.RaysThisFrame).to.equal(1)
		-- The session maximum survives new frames and counter resets.
		expect(snapshot.MaxRaysPerFrame).to.equal(3)
		Metrics.reset(controller)
		expect(Metrics.snapshot(controller).MaxRaysPerFrame).to.equal(3)
		expect(Metrics.snapshot(controller).Raycasts).to.equal(nil)
	end)
	end)
end
