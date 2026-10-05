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

	it("counts a ledge search's rays against the search, not the frame budget", function()
		Metrics.begin_frame(controller)
		Metrics.count_ray(controller)
		Metrics.measure_search(controller, "Mantle", function()
			for _ = 1, 60 do
				Metrics.count_ray(controller)
			end
		end)
		Metrics.count_ray(controller)

		local state = controller.Metrics
		expect(state.RaysThisFrame).to.equal(62)
		expect(state.SearchRaysThisFrame).to.equal(60)
		expect(state.SearchRays).to.equal(60)
		expect(state.SearchDepth).to.equal(0)
		-- Two steady rays: far under FrameRayBudget, so no frame warning is due.
		expect(state.RaysThisFrame - state.SearchRaysThisFrame).to.equal(2)

		Metrics.begin_frame(controller)
		expect(state.SearchRaysThisFrame).to.equal(0)
	end)

	it("unwinds the search depth when a search errors", function()
		local ok = pcall(Metrics.measure_search, controller, "Mantle", function()
			Metrics.count_ray(controller)
			error("search failed")
		end)
		expect(ok).to.equal(false)
		expect(controller.Metrics.SearchDepth).to.equal(0)

		-- Later rays count toward the frame budget again.
		Metrics.begin_frame(controller)
		Metrics.count_ray(controller)
		expect(controller.Metrics.SearchRaysThisFrame).to.equal(0)
	end)

	it("counts a nested search as part of the outer search", function()
		Metrics.measure_search(controller, "Outer", function()
			Metrics.count_ray(controller)
			Metrics.measure_search(controller, "Inner", function()
				Metrics.count_ray(controller)
			end)
			Metrics.count_ray(controller)
		end)
		expect(controller.Metrics.SearchRays).to.equal(3)
		expect(controller.Metrics.SearchDepth).to.equal(0)
	end)
	end)
end
