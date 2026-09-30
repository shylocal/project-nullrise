local StarterPlayer = game:GetService("StarterPlayer")
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local VaultMath = require(Client.controllers.ParkourController.VaultMath)

local function is_near(actual, expected, tolerance)
	return math.abs(actual - expected) <= (tolerance or 1e-6)
end

return function()
	describe("Parkour VaultMath", function()
		describe("smoothstep", function()
			it("clamps values below and above the unit interval", function()
				expect(VaultMath.smoothstep(-1)).to.equal(0)
				expect(VaultMath.smoothstep(2)).to.equal(1)
			end)

			it("has the expected endpoints and midpoint", function()
				expect(VaultMath.smoothstep(0)).to.equal(0)
				expect(VaultMath.smoothstep(0.5)).to.equal(0.5)
				expect(VaultMath.smoothstep(1)).to.equal(1)
			end)

			it("is monotonic across the normalized interval", function()
				local previous = VaultMath.smoothstep(0)
				for step = 1, 100 do
					local current = VaultMath.smoothstep(step / 100)
					expect(current >= previous).to.equal(true)
					previous = current
				end
			end)
		end)

		describe("arc_weight", function()
			it("starts and ends at zero with a unit peak", function()
				local peak = 0.5
				expect(is_near(VaultMath.arc_weight(0, peak), 0)).to.equal(true)
				expect(is_near(VaultMath.arc_weight(peak, peak), 1)).to.equal(true)
				expect(is_near(VaultMath.arc_weight(1, peak), 0)).to.equal(true)
			end)

			it("places the peak at the requested progress", function()
				for _, peak in ipairs({ 0.2, 0.35, 0.65, 0.92 }) do
					expect(is_near(VaultMath.arc_weight(peak, peak), 1)).to.equal(true)
				end
			end)

			it("clamps peak progress to its supported range", function()
				expect(is_near(VaultMath.arc_weight(0.2, -5), 1)).to.equal(true)
				expect(is_near(VaultMath.arc_weight(0.92, 5), 1)).to.equal(true)
			end)

			it("keeps the arc weight within zero and one over the flight", function()
				for _, peak in ipairs({ 0.2, 0.5, 0.92 }) do
					for step = 0, 100 do
						local weight = VaultMath.arc_weight(step / 100, peak)
						expect(weight >= -1e-6 and weight <= 1 + 1e-6).to.equal(true)
					end
				end
			end)
		end)

		describe("hip_height_weight", function()
			it("begins and ends at zero and reaches full crouch", function()
				expect(VaultMath.hip_height_weight(0)).to.equal(0)
				expect(VaultMath.hip_height_weight(0.5)).to.equal(1)
				expect(VaultMath.hip_height_weight(1)).to.equal(0)
			end)

			it("fades smoothly at the entry and exit boundaries", function()
				expect(is_near(VaultMath.hip_height_weight(0.09), 0.5)).to.equal(true)
				expect(is_near(VaultMath.hip_height_weight(0.96), 0.5)).to.equal(true)
			end)

			it("stays bounded for values before and after the vault", function()
				for step = -20, 120 do
					local weight = VaultMath.hip_height_weight(step / 100)
					expect(weight >= 0 and weight <= 1).to.equal(true)
				end
			end)
		end)
	end)
end
