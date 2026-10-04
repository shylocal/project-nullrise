local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

-- Mutable deep copy of a catalog definition, without the injected Id.
local function clone(weapon_id: string): any
	local copy: any = Freeze.clone_deep(Catalog.Get(weapon_id))
	copy.Id = nil
	return copy
end

local function has_error(errors: { string }, expected: string): boolean
	for _, message in ipairs(errors) do
		if message == expected then
			return true
		end
	end
	return false
end

local function expect_error(errors: { string }, expected: string)
	if not has_error(errors, expected) then
		error(("expected error %q, got:\n%s"):format(expected, table.concat(errors, "\n")), 2)
	end
end

return function()
	describe("Weapon definition validator", function()
		it("accepts the built-in definitions, with or without the injected Id", function()
			for _, weapon_id in ipairs(Catalog.Ids()) do
				expect(#Validator.check(Catalog.Get(weapon_id), weapon_id)).to.equal(0)
				expect(#Validator.check(clone(weapon_id), weapon_id)).to.equal(0)
			end
		end)

		it("rejects an unknown or misspelled Type with a single error", function()
			local invalid = clone("Fists")
			invalid.Type = "Mele"
			invalid.Model = 5
			local errors = Validator.check(invalid, "Fists")
			expect(#errors).to.equal(1)
			expect(errors[1]).to.equal("Fists.Type: must be one of: Melee")

			errors = Validator.check({ Type = "Ranged" }, "Bow")
			expect(#errors).to.equal(1)
			expect(errors[1]).to.equal("Bow.Type: must be one of: Melee")
		end)

		it("rejects non-table definitions", function()
			expect(Validator.check(nil, "X")[1]).to.equal("X: must be a table")
		end)

		it("collects every error instead of stopping at the first", function()
			local invalid = clone("Katana")
			invalid.Attacks[1].HitPositionTolerance = nil
			invalid.Attacks[2].Range = -1
			invalid.Model = ""
			local errors = Validator.check(invalid, "Katana")
			expect_error(errors, "Katana.Attacks[1].HitPositionTolerance: is required")
			expect_error(errors, "Katana.Attacks[2].Range: must be > 0")
			expect_error(errors, "Katana.Model: must not be empty")
		end)

		it("rejects unknown keys", function()
			local invalid = clone("Fists")
			invalid.MeleeType = "Blunt"
			invalid.Attacks[1].Damge = 10
			local errors = Validator.check(invalid, "Fists")
			expect_error(errors, "Fists.MeleeType: unknown key")
			expect_error(errors, "Fists.Attacks[1].Damge: unknown key")
		end)

		it("rejects malformed animation identifiers and priorities", function()
			local invalid = clone("Fists")
			invalid.Animations.Idle.Id = "not-an-asset"
			invalid.Animations.Equip.Priority = "Action"
			local errors = Validator.check(invalid, "Fists")
			expect_error(errors, "Fists.Animations.Idle.Id: must match ^rbxassetid://%d+$")
			expect_error(errors, "Fists.Animations.Equip.Priority: must be an Enum.AnimationPriority")
		end)

		it("requires server timing fields on every attack", function()
			for _, field in ipairs({ "HitStartAt", "HitWindow", "MinDuration" }) do
				local invalid = clone("Fists")
				invalid.Attacks[1][field] = nil
				expect_error(Validator.check(invalid, "Fists"), ("Fists.Attacks[1].%s: is required"):format(field))
			end
		end)

		it("rejects a client cooldown shorter than the server MinDuration", function()
			local invalid = clone("Fists")
			invalid.Attacks[1].Cooldown = invalid.Attacks[1].MinDuration / 2
			invalid.Charge.Cooldown = invalid.Charge.MinDuration / 2
			local errors = Validator.check(invalid, "Fists")
			expect(#errors).to.equal(2)
			expect_error(errors, "Fists.Attacks[1].Cooldown: must be >= MinDuration (0.3)")
			expect_error(errors, "Fists.Charge.Cooldown: must be >= MinDuration (0.6)")
		end)

		it("rejects a charge without a valid hold time or max hold", function()
			local missing_hold = clone("Fists")
			missing_hold.Charge.HoldTime = nil
			expect_error(Validator.check(missing_hold, "Fists"), "Fists.Charge.HoldTime: is required")

			local short_max_hold = clone("Fists")
			short_max_hold.Charge.MaxHoldTime = short_max_hold.Charge.HitStartAt
			expect_error(Validator.check(short_max_hold, "Fists"), "Fists.Charge.MaxHoldTime: must be > HitStartAt (0.15)")
		end)

		it("requires the charge animation if and only if a charge exists", function()
			local no_charge = clone("Fists")
			no_charge.Charge = nil
			expect_error(Validator.check(no_charge, "Fists"), "Fists.Animations.Charge: is only allowed with a Charge")

			no_charge.Animations.Charge = nil
			expect(#Validator.check(no_charge, "Fists")).to.equal(0)

			local no_animation = clone("Fists")
			no_animation.Animations.Charge = nil
			expect_error(Validator.check(no_animation, "Fists"), "Fists.Animations.Charge: is required")
		end)

		it("rejects sparse or empty attack sequences", function()
			local sparse = clone("Fists")
			sparse.Attacks[4] = sparse.Attacks[1]
			expect_error(Validator.check(sparse, "Fists"), "Fists.Attacks: must be a dense array")

			local empty = clone("Fists")
			empty.Attacks = {}
			expect_error(Validator.check(empty, "Fists"), "Fists.Attacks: must have at least 1 entries")
		end)

		it("requires SharedWith on a role that reuses an earlier animation id", function()
			local missing = clone("Katana")
			missing.Animations.Sprint.SharedWith = nil
			expect_error(Validator.check(missing, "Katana"), "Katana.Animations.Sprint.SharedWith: must be Idle (same animation Id)")

			local stray = clone("Fists")
			stray.Animations.Sprint.SharedWith = "Idle"
			expect_error(
				Validator.check(stray, "Fists"),
				"Fists.Animations.Sprint.SharedWith: must name an earlier role with the same animation Id"
			)
		end)

		it("merges AttackDefaults into every attack and the charge, authored keys winning", function()
			local definition = clone("Fists")
			definition.AttackDefaults = { Range = 8, HitPositionTolerance = 3 }
			for _, attack in ipairs(definition.Attacks) do
				attack.Range = nil
				attack.HitPositionTolerance = nil
			end
			definition.Charge.Range = nil
			definition.Attacks[2].Range = 5
			expect(#Validator.check(definition, "Fists")).to.equal(0)

			local resolved = Validator.resolve(definition)
			expect(resolved.AttackDefaults).to.equal(nil)
			expect(resolved.Attacks[1].Range).to.equal(8)
			expect(resolved.Attacks[2].Range).to.equal(5)
			expect(resolved.Charge.Range).to.equal(8)
			expect(resolved.Charge.HitPositionTolerance).to.equal(3)
			-- The authored definition is not modified.
			expect(definition.Attacks[1].Range).to.equal(nil)
		end)

		it("validates AttackDefaults fields", function()
			local definition = clone("Fists")
			definition.AttackDefaults = { Range = -1, Bogus = true }
			local errors = Validator.check(definition, "Fists")
			expect_error(errors, "Fists.AttackDefaults.Range: must be > 0")
			expect_error(errors, "Fists.AttackDefaults.Bogus: unknown key")
		end)

		it("keeps the boolean compatibility wrapper", function()
			expect((Validator.validate(Catalog.Get("Fists"), "Fists"))).to.equal(true)
			local invalid = clone("Fists")
			invalid.Attacks[1].HitPositionTolerance = nil
			local valid, reason = Validator.validate(invalid, "Fists")
			expect(valid).to.equal(false)
			expect(typeof(reason)).to.equal("string")
			expect((Validator.validate({ Type = "Ranged" }))).to.equal(false)
		end)

		it("exposes the melee kind", function()
			expect(Validator.KINDS.Melee).to.be.ok()
			expect((Validator :: any).validate_combat_config).to.equal(nil)
		end)
	end)
end
