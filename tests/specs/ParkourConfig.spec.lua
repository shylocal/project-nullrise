local StarterPlayer = game:GetService("StarterPlayer")
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local Config = require(Client.controllers.ParkourController.Config)

local function is_finite_nonnegative(value)
	return typeof(value) == "number" and math.isfinite(value) and value >= 0
end

return function()
	describe("Parkour configuration", function()
		it("defines valid grab and traversal distances", function()
			expect(is_finite_nonnegative(Config.WallReach) and Config.WallReach > 0).to.equal(true)
			expect(is_finite_nonnegative(Config.MaxGrabHeight) and Config.MaxGrabHeight > 0).to.equal(true)
			expect(is_finite_nonnegative(Config.HangDrop)).to.equal(true)
			expect(is_finite_nonnegative(Config.WallGap)).to.equal(true)
			expect(is_finite_nonnegative(Config.TraverseSpeed)).to.equal(true)
			expect(is_finite_nonnegative(Config.TraverseSprintMultiplier)).to.equal(true)
		end)

		it("keeps generic tall-wall and ordinary vault classifications distinct", function()
			expect(is_finite_nonnegative(Config.TallWallMinHeight)).to.equal(true)
			expect(Config.TallWallMinHeight > Config.VaultMaxHeight).to.equal(true)
			expect(Config.VaultMinHeight > 0).to.equal(true)
			expect(Config.VaultMaxHeight > Config.VaultMinHeight).to.equal(true)
			expect(Config.VaultFarSideOnlyHeight > 0).to.equal(true)
		end)

		it("uses finite, nonnegative vault tuning and coherent ranges", function()
			local nonnegative_fields = {
				"VaultDetectionDistance",
				"VaultDetectionHeight",
				"VaultLandingGap",
				"VaultMaxHopDistance",
				"VaultMaxOverDistance",
				"VaultTopLandingInset",
				"VaultLandingHeightTolerance",
				"VaultMinArcHeight",
				"VaultMaxArcHeight",
				"VaultObstacleClearance",
				"VaultTallObstacleClearancePerStud",
				"VaultTallDurationPerStud",
				"VaultTopHopHeightMargin",
				"VaultTopHopForwardBoostSpeed",
				"VaultDuration",
				"VaultCooldown",
				"VaultForwardBoostSpeed",
				"VaultHipHeightReduction",
			}
			for _, field in ipairs(nonnegative_fields) do
				expect(is_finite_nonnegative(Config[field])).to.equal(true)
			end

			expect(Config.VaultMaxArcHeight >= Config.VaultMinArcHeight).to.equal(true)
			expect(Config.VaultMaxHopDistance >= Config.VaultMaxOverDistance).to.equal(true)
			expect(Config.VaultDurationMultiplier >= 0.5 and Config.VaultDurationMultiplier <= 1.5).to.equal(true)
			expect(typeof(Config.VaultEnabled)).to.equal("boolean")
		end)
	end)
end
