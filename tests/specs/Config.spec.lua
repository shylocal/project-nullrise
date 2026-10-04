local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.shared.config)
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)
local HitboxSettings = require(ReplicatedStorage.packages.ShapecastHitbox.Settings)

local SECTION_NAMES = { "Movement", "Parkour", "Combat", "Inventory", "World", "Network", "Data", "Telemetry" }

-- Mutable deep copy of every section (without `validate`), for breaking.
local function sections(): any
	local copy = {}
	for _, name in ipairs(SECTION_NAMES) do
		copy[name] = Freeze.clone_deep((Config :: any)[name])
	end
	return copy
end

local function expect_error(errors: { string }, expected: string)
	if table.find(errors, expected) == nil then
		error(("expected error %q, got:\n%s"):format(expected, table.concat(errors, "\n")), 2)
	end
end

return function()
	describe("Config tree", function()
		it("loads every section and is deep-frozen", function()
			for _, name in ipairs(SECTION_NAMES) do
				local section = (Config :: any)[name]
				expect(typeof(section)).to.equal("table")
				expect(table.isfrozen(section)).to.equal(true)
			end
			expect(table.isfrozen(Config)).to.equal(true)
			expect(table.isfrozen(Config.Movement.Envelope)).to.equal(true)
			expect(table.isfrozen(Config.Network.RemoteBudget.Actions["Combat.Hit"])).to.equal(true)
		end)

		it("validates the shipped config without errors", function()
			local errors = Config.validate(sections())
			if #errors > 0 then
				error(table.concat(errors, "\n"), 0)
			end
		end)

		it("keeps feel-critical values unchanged", function()
			expect(Config.Movement.WalkSpeed).to.equal(16)
			expect(Config.Movement.SprintSpeed).to.equal(24)
			expect(Config.Movement.SprintMinMoveMagnitude).to.equal(0.1)
			expect(Config.Combat.TimingTolerance).to.equal(0.1)
			expect(Config.Combat.PendingAttackTimeout).to.equal(1)
			expect(Config.Parkour.WallReach).to.equal(4.25)
			expect(Config.Parkour.VaultDuration).to.equal(0.42)
			expect(Config.Parkour.VaultDurationMultiplier).to.equal(0.95)
			expect(Config.Parkour.MantleDuration).to.equal(0.35)
			expect(Config.Parkour.TraverseSpeed).to.equal(7)
		end)

		it("matches the ShapecastHitbox hitpoint tag", function()
			expect(Config.World.Tags.Hitpoint).to.equal(HitboxSettings.Tag)
		end)

		it("moves climbable names out of Parkour into World", function()
			expect((Config.Parkour :: any).ClimbableTag).to.equal(nil)
			expect((Config.Parkour :: any).ClimbableCollisionGroup).to.equal(nil)
			expect(Config.World.Tags.Climbable).to.equal("Climbable")
			expect(Config.World.CollisionGroups.Climbable).to.equal("Climbable")
		end)
	end)

	describe("Config.validate", function()
		it("collects every error across sections", function()
			local broken = sections()
			broken.Movement.WalkSpeed = -1
			broken.Movement.Envelope.HorizontalMargin = "wide"
			broken.Combat.MaxHitsPerAttack = 2.5
			broken.Telemetry.Weights.Reach = -1
			local errors = Config.validate(broken)
			expect(#errors).to.equal(4)
			expect_error(errors, "Movement.WalkSpeed: must be > 0")
			expect_error(errors, "Movement.Envelope.HorizontalMargin: must be a number")
			expect_error(errors, "Combat.MaxHitsPerAttack: must be an integer")
			expect_error(errors, "Telemetry.Weights.Reach: must be >= 0")
		end)

		it("rejects unknown keys and missing sections", function()
			local broken = sections()
			broken.Movement.RunSpeed = 30
			broken.Data = nil
			broken.Extra = {}
			local errors = Config.validate(broken)
			expect_error(errors, "Movement.RunSpeed: unknown key")
			expect_error(errors, "Data: is required")
			expect_error(errors, "Extra: unknown key")
		end)

		it("enforces the parkour rules", function()
			local broken = sections()
			broken.Parkour.VaultEnabled = 1
			broken.Parkour.VaultDurationMultiplier = 1.6
			broken.Parkour.WallReach = -0.1
			broken.Parkour.MaxTopSurfaceHits = 0
			broken.Parkour.FrameRayBudget = 4.5
			broken.Parkour.CornerProbeRecheckDistance = broken.Parkour.CornerLockDistance
			local errors = Config.validate(broken)
			expect(#errors).to.equal(6)
			expect_error(errors, "Parkour.VaultEnabled: must be a boolean")
			expect_error(errors, "Parkour.VaultDurationMultiplier: must be <= 1.5")
			expect_error(errors, "Parkour.WallReach: must be >= 0")
			expect_error(errors, "Parkour.MaxTopSurfaceHits: must be > 0")
			expect_error(errors, "Parkour.FrameRayBudget: must be an integer")
			expect_error(errors, "Parkour.CornerProbeRecheckDistance: must be < Parkour.CornerLockDistance")
		end)

		it("keeps tall-wall and ordinary vault classifications distinct", function()
			local parkour = Config.Parkour
			expect(parkour.TallWallMinHeight > parkour.VaultMaxHeight).to.equal(true)
			expect(parkour.VaultMinHeight > 0).to.equal(true)
			expect(parkour.VaultMaxHeight > parkour.VaultMinHeight).to.equal(true)
			expect(parkour.VaultMaxArcHeight >= parkour.VaultMinArcHeight).to.equal(true)
			expect(parkour.VaultTopHopTimeout > 0).to.equal(true)
			expect((parkour :: any).VaultMaxHopDistance).to.equal(nil)
		end)

		it("requires hit requests to cover the hit cap", function()
			local broken = sections()
			broken.Combat.MaxHitRequestsPerAttack = broken.Combat.MaxHitsPerAttack - 1
			local errors = Config.validate(broken)
			expect(#errors).to.equal(1)
			expect(errors[1]).to.equal("Combat.MaxHitRequestsPerAttack: must be >= Combat.MaxHitsPerAttack")
		end)

		it("validates remote budget entries", function()
			local broken = sections()
			broken.Network.RemoteBudget.Actions["Combat.Hit"].Burst = 0
			broken.Network.RemoteBudget.Actions.Bogus = { Rate = 1, Burst = 1 }
			local errors = Config.validate(broken)
			expect_error(errors, 'Network.RemoteBudget.Actions["Combat.Hit"].Burst: must be >= 1')
			expect_error(errors, "Network.RemoteBudget.Actions.Bogus: must match ^%a+%.%a+$")
		end)

		it("rejects a non-table", function()
			local errors = Config.validate(nil)
			expect(#errors).to.equal(1)
			expect(errors[1]).to.equal("(root): must be a table")
		end)
	end)
end
