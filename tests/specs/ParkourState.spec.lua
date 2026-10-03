local StarterPlayer = game:GetService("StarterPlayer")
local State = require(
	StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client"):WaitForChild("controllers"):WaitForChild("ParkourController"):WaitForChild("State")
)

return function()
	describe("Parkour state data ownership", function()
		it("stores and replaces per-state data records", function()
			local controller = { _stateData = {} }

			local first = State.set_data(controller, "Vault", {
				Duration = 1,
				Elapsed = 0,
			})
			expect(State.get_data(controller, "Vault")).to.equal(first)
			expect(first.Duration).to.equal(1)

			local second = State.set_data(controller, "Vault", {
				Duration = 2,
			})
			expect(second).to.equal(first)
			expect(second.Duration).to.equal(2)
			expect(second.Elapsed).to.equal(nil)
		end)

		it("clears one state without disturbing another", function()
			local controller = { _stateData = {} }
			State.set_data(controller, "Vault", { Duration = 1 })
			State.set_data(controller, "TopHop", { StartedAt = 123 })

			State.clear_data(controller, "Vault")

			expect(State.get_data(controller, "Vault")).to.equal(nil)
			expect(State.get_data(controller, "TopHop").StartedAt).to.equal(123)
		end)

		it("clears every state record", function()
			local controller = { _stateData = {} }
			State.set_data(controller, "Vault", { Duration = 1 })
			State.set_data(controller, "TopHop", { StartedAt = 123 })

			State.clear_all_data(controller)

			expect(State.get_data(controller, "Vault")).to.equal(nil)
			expect(State.get_data(controller, "TopHop")).to.equal(nil)
		end)
	end)
end