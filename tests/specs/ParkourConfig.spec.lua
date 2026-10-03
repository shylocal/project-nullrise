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
				"VaultTopHopTimeout",
				"VaultDuration",
				"VaultCooldown",
				"VaultForwardBoostSpeed",
				"VaultHipHeightReduction",
			}
			for _, field in ipairs(nonnegative_fields) do
				expect(is_finite_nonnegative(Config[field])).to.equal(true)
			end

			expect(Config.VaultMaxArcHeight >= Config.VaultMinArcHeight).to.equal(true)
			expect(Config.VaultMaxOverDistance > 0).to.equal(true)
			expect(Config.VaultTopHopTimeout > 0).to.equal(true)
			expect(Config.VaultDurationMultiplier >= 0.5 and Config.VaultDurationMultiplier <= 1.5).to.equal(true)
			expect(typeof(Config.VaultEnabled)).to.equal("boolean")
		end)

		it("drops the shadowed hop-distance knob in favour of the effective cap", function()
			-- VaultMaxOverDistance is the only scripted-vault distance limit.
			expect(Config.VaultMaxHopDistance).to.equal(nil)
		end)

		it("defines the mantle and corner-probe timings used by traversal", function()
			expect(is_finite_nonnegative(Config.MantleDuration) and Config.MantleDuration > 0).to.equal(true)
			expect(is_finite_nonnegative(Config.CornerProbeRecheckDistance)
				and Config.CornerProbeRecheckDistance > 0).to.equal(true)
			-- A recheck distance at or beyond the corner lock would let straight
			-- traversal carry the hang past a corner before the fan re-runs.
			expect(Config.CornerProbeRecheckDistance < Config.CornerLockDistance).to.equal(true)
		end)
	end)
end
