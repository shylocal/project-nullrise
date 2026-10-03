local StarterPlayer = game:GetService("StarterPlayer")
local ParkourFolder = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client"):WaitForChild("controllers"):WaitForChild("ParkourController")
local State = require(ParkourFolder:WaitForChild("State"))
local VaultTraversal = require(ParkourFolder:WaitForChild("VaultTraversal"))

local function make_controller(top_hop)
	local controller = {
		_stateData = {},
		Humanoid = { Parent = true, JumpPower = 0, JumpHeight = 0 },
	}
	State.set_data(controller, "TopHop", top_hop)
	return controller
end

return function()
	describe("Vault top-hop jump restore", function()
		it("restores the native jump setting while keeping the hop guard", function()
			local disconnected = false
			local controller = make_controller({
				StartedAt = 0,
				SawAir = false,
				UseJumpPower = true,
				JumpPowerBefore = 50,
				JumpHeightBefore = 7.2,
				StateConnection = {
					Disconnect = function()
						disconnected = true
					end,
				},
			})

			VaultTraversal.restore_top_hop_jump(controller)

			expect(controller.Humanoid.JumpPower).to.equal(50)
			expect(disconnected).to.equal(true)
			-- The record stays until landing so it still blocks re-vaults.
			expect(State.get_data(controller, "TopHop")).to.be.ok()
		end)

		it("does not overwrite jump settings changed after the restore", function()
			local controller = make_controller({
				StartedAt = 0,
				SawAir = false,
				UseJumpPower = false,
				JumpPowerBefore = 50,
				JumpHeightBefore = 7.2,
			})

			VaultTraversal.restore_top_hop_jump(controller)
			controller.Humanoid.JumpHeight = 10
			VaultTraversal.finish_top_hop(controller, true)

			expect(controller.Humanoid.JumpHeight).to.equal(10)
			expect(State.get_data(controller, "TopHop")).to.equal(nil)
		end)

		it("restores jump when the hop finishes before the launch state ended", function()
			local controller = make_controller({
				StartedAt = 0,
				SawAir = false,
				UseJumpPower = true,
				JumpPowerBefore = 50,
				JumpHeightBefore = 7.2,
			})

			VaultTraversal.finish_top_hop(controller, false)

			expect(controller.Humanoid.JumpPower).to.equal(50)
			expect(State.get_data(controller, "TopHop")).to.equal(nil)
		end)
	end)
end
