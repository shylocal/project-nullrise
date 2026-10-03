local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local CombatConfig = require(ReplicatedStorage.shared.weapons.CombatConfig)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

-- Returns a copy of Fists whose first attack and charge can be edited without
-- touching the shared definition.
local function clone_fists()
	local fists = Catalog.Get("Fists")
	local invalid = table.clone(fists)
	invalid.Attacks = table.clone(fists.Attacks)
	invalid.Attacks[1] = table.clone(fists.Attacks[1])
	invalid.Charge = table.clone(fists.Charge)
	return invalid
end

return function()
	describe("Weapon definition validator", function()
		it("accepts the built-in melee definitions", function()
			expect(Validator.validate(Catalog.Get("Fists"))).to.equal(true)
			expect(Validator.validate(Catalog.Get("Katana"))).to.equal(true)
		end)

		it("rejects malformed melee definitions", function()
			local invalid = clone_fists()
			invalid.Attacks[1].HitPositionTolerance = nil

			local valid, reason = Validator.validate(invalid)
			expect(valid).to.equal(false)
			expect(typeof(reason)).to.equal("string")
		end)

		it("does not impose melee-only fields on other weapon types", function()
			expect(Validator.validate({ Type = "Ranged" })).to.equal(true)
		end)

		it("rejects malformed animation identifiers", function()
			local fists = Catalog.Get("Fists")
			local invalid = table.clone(fists)
			invalid.Animations = table.clone(fists.Animations)
			invalid.Animations.Idle = table.clone(fists.Animations.Idle)
			invalid.Animations.Idle.Id = "not-an-asset"

			expect(Validator.validate(invalid)).to.equal(false)
		end)

		it("requires server timing fields on every attack", function()
			for _, field in ipairs({ "HitStartAt", "HitWindow", "MinDuration" }) do
				local invalid = clone_fists()
				invalid.Attacks[1][field] = nil

				expect(Validator.validate(invalid)).to.equal(false)
			end
		end)

		it("rejects a client cooldown shorter than the server MinDuration", function()
			local invalid = clone_fists()
			invalid.Attacks[1].Cooldown = invalid.Attacks[1].MinDuration / 2

			expect(Validator.validate(invalid)).to.equal(false)
		end)

		it("rejects a charge without a valid hold time or max hold", function()
			local missing_hold = clone_fists()
			missing_hold.Charge.HoldTime = nil
			expect(Validator.validate(missing_hold)).to.equal(false)

			local short_max_hold = clone_fists()
			short_max_hold.Charge.MaxHoldTime = short_max_hold.Charge.HitStartAt
			expect(Validator.validate(short_max_hold)).to.equal(false)
		end)

		it("rejects sparse attack sequences", function()
			local invalid = clone_fists()
			invalid.Attacks[4] = invalid.Attacks[1]

			expect(Validator.validate(invalid)).to.equal(false)
		end)

		it("accepts the shared combat config and rejects invalid values", function()
			expect(Validator.validate_combat_config(CombatConfig)).to.equal(true)

			local invalid = table.clone(CombatConfig)
			invalid.PendingAttackTimeout = 0
			expect(Validator.validate_combat_config(invalid)).to.equal(false)

			invalid = table.clone(CombatConfig)
			invalid.TimingTolerance = nil
			expect(Validator.validate_combat_config(invalid)).to.equal(false)
		end)
	end)
end
