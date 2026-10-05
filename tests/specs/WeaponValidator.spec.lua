--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

-- Mutable deep copy of a catalog definition in authored form: without the
-- injected weapon Id and move Name/Id.
local function clone(weapon_id: string): any
	local copy: any = Freeze.clone_deep(Catalog.Get(weapon_id))
	copy.Id = nil
	for _, move in pairs(copy.Moves) do
		move.Name = nil
		move.Id = nil
	end
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
		it("accepts the built-in definitions, in catalog and authored form", function()
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
			invalid.Moves.Light1.Damage = nil
			invalid.Moves.Light2.Range = -1
			invalid.Model = ""
			local errors = Validator.check(invalid, "Katana")
			expect_error(errors, "Katana.Moves.Light1.Damage: is required")
			expect_error(errors, "Katana.Moves.Light2.Range: must be > 0")
			expect_error(errors, "Katana.Model: must not be empty")
		end)

		it("rejects unknown keys", function()
			local invalid = clone("Fists")
			invalid.MeleeType = "Blunt"
			invalid.Moves.Light1.Damge = 10
			invalid.Attacks = {}
			local errors = Validator.check(invalid, "Fists")
			expect_error(errors, "Fists.MeleeType: unknown key")
			expect_error(errors, "Fists.Moves.Light1.Damge: unknown key")
			expect_error(errors, "Fists.Attacks: unknown key")
		end)

		it("rejects the removed charge animation role", function()
			local invalid = clone("Fists")
			invalid.Animations.Charge = invalid.Moves.Heavy.Animation
			expect_error(Validator.check(invalid, "Fists"), "Fists.Animations.Charge: unknown key")
		end)

		it("rejects malformed animation identifiers and priorities", function()
			local invalid = clone("Fists")
			invalid.Animations.Idle.Id = "not-an-asset"
			invalid.Animations.Equip.Priority = "Action"
			invalid.Moves.Light1.Animation.Id = "nope"
			local errors = Validator.check(invalid, "Fists")
			expect_error(errors, "Fists.Animations.Idle.Id: must match ^rbxassetid://%d+$")
			expect_error(errors, "Fists.Animations.Equip.Priority: must be an Enum.AnimationPriority")
			expect_error(errors, "Fists.Moves.Light1.Animation.Id: must match ^rbxassetid://%d+$")
		end)

		it("requires server timing fields and a kind on every move", function()
			for _, field in ipairs({ "HitStartAt", "HitWindow", "MinDuration", "Kind" }) do
				local invalid = clone("Fists")
				invalid.Moves.Light1[field] = nil
				expect_error(Validator.check(invalid, "Fists"), ("Fists.Moves.Light1.%s: is required"):format(field))
			end

			local bad_kind = clone("Fists")
			bad_kind.Moves.Light1.Kind = "Heavy"
			expect_error(Validator.check(bad_kind, "Fists"), "Fists.Moves.Light1.Kind: must be one of: Light, Charge")
		end)

		it("rejects badly named moves", function()
			local invalid = clone("Fists")
			invalid.Moves["1Punch"] = invalid.Moves.Light1
			expect_error(Validator.check(invalid, "Fists"), 'Fists.Moves["1Punch"]: must match ^%a[%w_]*$')

			local reserved = clone("Fists")
			reserved.Moves.Combo = reserved.Moves.Light1
			expect_error(Validator.check(reserved, "Fists"), "Fists.Moves.Combo: is a reserved name")
		end)

		it("rejects a client cooldown shorter than the server MinDuration", function()
			local invalid = clone("Fists")
			invalid.Moves.Light1.Cooldown = invalid.Moves.Light1.MinDuration / 2
			invalid.Moves.Heavy.Cooldown = invalid.Moves.Heavy.MinDuration / 2
			local errors = Validator.check(invalid, "Fists")
			expect(#errors).to.equal(2)
			expect_error(errors, "Fists.Moves.Light1.Cooldown: must be >= MinDuration (0.35)")
			expect_error(errors, "Fists.Moves.Heavy.Cooldown: must be >= MinDuration (0.6)")
		end)

		it("requires Hold if and only if the move is a Charge move", function()
			local missing_hold = clone("Fists")
			missing_hold.Moves.Heavy.Hold = nil
			expect_error(Validator.check(missing_hold, "Fists"), "Fists.Moves.Heavy.Hold: is required for a Charge move")

			local light_hold = clone("Fists")
			light_hold.Moves.Light1.Hold = { HoldTime = 0.15, MaxHoldTime = 10 }
			expect_error(Validator.check(light_hold, "Fists"), "Fists.Moves.Light1.Hold: is only allowed on a Charge move")

			local missing_hold_time = clone("Fists")
			missing_hold_time.Moves.Heavy.Hold.HoldTime = nil
			expect_error(Validator.check(missing_hold_time, "Fists"), "Fists.Moves.Heavy.Hold.HoldTime: is required")

			local short_max_hold = clone("Fists")
			short_max_hold.Moves.Heavy.Hold.MaxHoldTime = short_max_hold.Moves.Heavy.HitStartAt
			expect_error(
				Validator.check(short_max_hold, "Fists"),
				"Fists.Moves.Heavy.Hold.MaxHoldTime: must be > HitStartAt (0.15)"
			)
		end)

		it("requires the combo to list Light moves", function()
			local unknown = clone("Fists")
			unknown.Combo = { "Light1", "Light3" }
			expect_error(Validator.check(unknown, "Fists"), "Fists.Combo[2]: Light3 is not a move")

			local charge = clone("Fists")
			charge.Combo = { "Light1", "Light2", "Heavy" }
			expect_error(Validator.check(charge, "Fists"), "Fists.Combo[3]: Heavy must be a Light move")

			local empty = clone("Fists")
			empty.Combo = {}
			expect_error(Validator.check(empty, "Fists"), "Fists.Combo: must have at least 1 entries")

			local sparse = clone("Fists")
			sparse.Combo[4] = "Light1"
			expect_error(Validator.check(sparse, "Fists"), "Fists.Combo: must be a dense array")
		end)

		it("checks the primary bindings", function()
			local bad_tap = clone("Fists")
			bad_tap.Bindings.Primary.Tap = "Swing"
			expect_error(Validator.check(bad_tap, "Fists"), "Fists.Bindings.Primary.Tap: must be Combo or a move name")

			local bad_hold = clone("Fists")
			bad_hold.Bindings.Primary.Hold = "Light1"
			expect_error(Validator.check(bad_hold, "Fists"), "Fists.Bindings.Primary.Hold: Light1 must be a Charge move")

			local unknown_hold = clone("Fists")
			unknown_hold.Bindings.Primary.Hold = "Spin"
			expect_error(Validator.check(unknown_hold, "Fists"), "Fists.Bindings.Primary.Hold: Spin is not a move")

			local direct_tap = clone("Fists")
			direct_tap.Bindings.Primary.Tap = "Light1"
			expect(#Validator.check(direct_tap, "Fists")).to.equal(0)
		end)

		it("requires every move to be reachable from Combo or Bindings", function()
			local unbound = clone("Fists")
			unbound.Bindings.Primary.Hold = nil
			expect_error(Validator.check(unbound, "Fists"), "Fists.Moves.Heavy: is not reachable from Combo or Bindings")
		end)

		it("forbids authored move Name and Id and checks injected ones", function()
			local authored = clone("Fists")
			authored.Moves.Light1.Name = "Light1"
			authored.Moves.Light1.Id = 2
			local errors = Validator.check(authored, "Fists")
			expect_error(errors, "Fists.Moves.Light1.Name: is injected by the Catalog")
			expect_error(errors, "Fists.Moves.Light1.Id: is injected by the Catalog")

			local catalog: any = Freeze.clone_deep(Catalog.Get("Fists"))
			catalog.Moves.Light1.Id = 1
			catalog.Moves.Light2.Name = "Light9"
			errors = Validator.check(catalog, "Fists")
			expect_error(errors, "Fists.Moves.Light1.Id: must be 2")
			expect_error(errors, "Fists.Moves.Light2.Name: must be Light2")
		end)

		it("assigns move ids by sorted name", function()
			local ids = Validator.move_ids({ Light2 = {}, Heavy = {}, Light1 = {} })
			expect(ids.Heavy).to.equal(1)
			expect(ids.Light1).to.equal(2)
			expect(ids.Light2).to.equal(3)
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

		it("merges MoveDefaults into every move, authored keys winning", function()
			local definition = clone("Fists")
			definition.MoveDefaults = { Range = 8, HitPositionTolerance = 3 }
			for _, move in pairs(definition.Moves) do
				move.Range = nil
				move.HitPositionTolerance = nil
			end
			definition.Moves.Light2.Range = 5
			expect(#Validator.check(definition, "Fists")).to.equal(0)

			local resolved = Validator.resolve(definition)
			expect(resolved.MoveDefaults).to.equal(nil)
			expect(resolved.Moves.Light1.Range).to.equal(8)
			expect(resolved.Moves.Light2.Range).to.equal(5)
			expect(resolved.Moves.Heavy.Range).to.equal(8)
			expect(resolved.Moves.Heavy.HitPositionTolerance).to.equal(3)
			-- The authored definition is not modified.
			expect(definition.Moves.Light1.Range).to.equal(nil)
		end)

		it("validates MoveDefaults fields", function()
			local definition = clone("Fists")
			definition.MoveDefaults = { Range = -1, Bogus = true }
			local errors = Validator.check(definition, "Fists")
			expect_error(errors, "Fists.MoveDefaults.Range: must be > 0")
			expect_error(errors, "Fists.MoveDefaults.Bogus: unknown key")
		end)

		it("keeps the boolean compatibility wrapper", function()
			expect((Validator.validate(Catalog.Get("Fists"), "Fists"))).to.equal(true)
			local invalid = clone("Fists")
			invalid.Moves.Light1.HitPositionTolerance = nil
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
