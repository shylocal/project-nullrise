local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Config = require(ReplicatedStorage.shared.config)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

return function()
	describe("Weapon Catalog", function()
		it("loads the built-in melee weapon definitions", function()
			local fists = Catalog.Get("Fists")
			local katana = Catalog.Get("Katana")

			expect(fists).to.be.ok()
			expect(katana).to.be.ok()
			expect(Catalog.IsEquippable(fists)).to.equal(true)
			expect(Catalog.IsEquippable(katana)).to.equal(true)
		end)

		it("names Fists as the default weapon", function()
			expect(Catalog.DefaultId).to.equal("Fists")
			expect(Catalog.Has(Catalog.DefaultId)).to.equal(true)
		end)

		it("lists ids and definitions in the same order", function()
			local ids = Catalog.Ids()
			local all = Catalog.All()
			expect(#ids).to.equal(#all)
			expect(#ids >= 2).to.equal(true)
			for index, weapon_id in ipairs(ids) do
				expect(all[index]).to.equal(Catalog.Get(weapon_id))
				expect(all[index].Id).to.equal(weapon_id)
			end
			expect(table.isfrozen(ids)).to.equal(true)
			expect(table.isfrozen(all)).to.equal(true)
		end)

		it("returns validated definitions", function()
			for _, weapon_id in ipairs(Catalog.Ids()) do
				expect(#Validator.check(Catalog.Get(weapon_id), weapon_id)).to.equal(0)
				expect((Validator.validate(Catalog.Get(weapon_id), weapon_id))).to.equal(true)
			end
		end)

		it("returns the same deep-frozen definition on every lookup", function()
			local fists = Catalog.Get("Fists")
			expect(fists).to.equal(Catalog.Get("Fists"))
			expect(table.isfrozen(fists)).to.equal(true)
			expect(table.isfrozen(fists.Attacks)).to.equal(true)
			expect(table.isfrozen(fists.Attacks[1].Animation)).to.equal(true)
			expect(table.isfrozen(fists.Wield)).to.equal(true)
			expect(pcall(function()
				(fists :: any).Model = "Changed"
			end)).to.equal(false)
		end)

		it("keeps the charge animation shared with the charge role", function()
			local fists = Catalog.Get("Fists")
			assert(fists and fists.Charge and fists.Animations.Charge, "Fists must define a charge")
			expect(fists.Charge.Animation).to.equal(fists.Animations.Charge)
		end)

		it("keeps every feel-critical number unchanged", function()
			-- { Hitbox, Damage, Cooldown, MinDuration, HitStartAt, HitWindow, Tolerance, Range }
			local golden = {
				Fists = {
					Attacks = {
						{ "RightFist", 10, 0.3, 0.3, 0.1, 0.55, 3, 8 },
						{ "LeftFist", 10, 0.3, 0.3, 0.1, 0.55, 3, 8 },
					},
					Charge = { "RightFist", 20, 0.6, 0.6, 0.15, 0.55, 3, 8 },
				},
				Katana = {
					Attacks = {
						{ "Mesh", 15, 0.35, 0.35, 0.1, 0.55, 3, 10 },
						{ "Mesh", 15, 0.35, 0.35, 0.1, 0.55, 3, 10 },
					},
					Charge = { "Mesh", 30, 0.6, 0.6, 0.15, 0.55, 3, 10 },
				},
			}
			local fields = { "Hitbox", "Damage", "Cooldown", "MinDuration", "HitStartAt", "HitWindow", "HitPositionTolerance", "Range" }
			local function expect_attack(attack: any, values: { any })
				for index, field in ipairs(fields) do
					expect(attack[field]).to.equal(values[index])
				end
			end
			for weapon_id, expected in pairs(golden) do
				local weapon = Catalog.Get(weapon_id) :: any
				expect(#weapon.Attacks).to.equal(#expected.Attacks)
				for index, values in ipairs(expected.Attacks) do
					expect_attack(weapon.Attacks[index], values)
				end
				expect_attack(weapon.Charge, expected.Charge)
				expect(weapon.Charge.HoldTime).to.equal(0.15)
				expect(weapon.Charge.MaxHoldTime).to.equal(10)
				expect(weapon.CanSprintWhileAttacking).to.equal(true)
			end
		end)

		it("returns nil for invalid or unknown identifiers", function()
			expect(Catalog.Get("")).to.equal(nil)
			expect(Catalog.Get("MissingWeapon")).to.equal(nil)
			expect(Catalog.Get(123)).to.equal(nil)
			expect(Catalog.Has("MissingWeapon")).to.equal(false)
			expect(Catalog.Has(nil)).to.equal(false)
		end)

		it("never returns sibling support modules as weapons", function()
			for _, name in ipairs({ "Catalog", "Validator", "Loadouts", "Types", "AnimationContracts" }) do
				expect(Catalog.Get(name)).to.equal(nil)
				expect(Catalog.Has(name)).to.equal(false)
			end
		end)

		it("only treats catalog definitions of a known kind as equippable", function()
			local copy = table.clone(Catalog.Get("Katana") :: any)
			expect(Catalog.IsEquippable(copy)).to.equal(true)
			expect(Catalog.IsEquippable({ Type = "Melee" })).to.equal(false)
			expect(Catalog.IsEquippable({ Id = "Katana", Type = "Ranged" })).to.equal(false)
			expect(Catalog.IsEquippable({ Id = "Missing", Type = "Melee" })).to.equal(false)
			expect(Catalog.IsEquippable(nil)).to.equal(false)
		end)

		it("exposes the starter loadout", function()
			local starter = Catalog.Loadout("Starter")
			expect(starter[2]).to.equal("Katana")
			expect(table.isfrozen(starter)).to.equal(true)
			for slot, weapon_id in pairs(starter) do
				expect(slot >= 1 and slot <= Config.Inventory.MaxSlots).to.equal(true)
				expect(weapon_id ~= Catalog.DefaultId).to.equal(true)
				expect(Catalog.IsEquippable(Catalog.Get(weapon_id))).to.equal(true)
			end
		end)

		it("errors on an unknown loadout", function()
			expect(function()
				Catalog.Loadout("Missing")
			end).to.throw()
		end)
	end)
end
