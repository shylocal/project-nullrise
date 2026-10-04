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
			expect(table.isfrozen(fists.Moves)).to.equal(true)
			expect(table.isfrozen(fists.Moves.Light1.Animation)).to.equal(true)
			expect(table.isfrozen(fists.Combo)).to.equal(true)
			expect(table.isfrozen(fists.Bindings.Primary)).to.equal(true)
			expect(table.isfrozen(fists.Wield)).to.equal(true)
			expect(pcall(function()
				(fists :: any).Model = "Changed"
			end)).to.equal(false)
		end)

		it("assigns move ids by sorted move name and injects Name and Id", function()
			for _, weapon_id in ipairs(Catalog.Ids()) do
				local weapon = Catalog.Get(weapon_id) :: any
				local names = {}
				for name in pairs(weapon.Moves) do
					table.insert(names, name)
				end
				table.sort(names)
				for index, name in ipairs(names) do
					local move = weapon.Moves[name]
					expect(move.Name).to.equal(name)
					expect(move.Id).to.equal(index)
					expect(Catalog.MoveId(weapon_id, name)).to.equal(index)
					expect(Catalog.GetMove(weapon_id, index)).to.equal(move)
				end
			end
			expect(Catalog.MoveId("Fists", "Heavy")).to.equal(1)
			expect(Catalog.MoveId("Fists", "Light1")).to.equal(2)
			expect(Catalog.MoveId("Fists", "Light2")).to.equal(3)
		end)

		it("returns nil for unknown moves", function()
			expect(Catalog.GetMove("Fists", 99)).to.equal(nil)
			expect(Catalog.GetMove("Fists", "1")).to.equal(nil)
			expect(Catalog.GetMove("Fists", nil)).to.equal(nil)
			expect(Catalog.GetMove("Missing", 1)).to.equal(nil)
			expect(Catalog.MoveId("Fists", "Missing")).to.equal(nil)
			expect(Catalog.MoveId("Missing", "Light1")).to.equal(nil)
		end)

		it("maps combo positions to move ids and rejects other positions", function()
			local fists = Catalog.Get("Fists") :: any
			expect(Catalog.ComboMoveId(fists, 1)).to.equal(Catalog.MoveId("Fists", "Light1"))
			expect(Catalog.ComboMoveId(fists, 2)).to.equal(Catalog.MoveId("Fists", "Light2"))
			expect(function()
				Catalog.ComboMoveId(fists, 0)
			end).to.throw()
			expect(function()
				Catalog.ComboMoveId(fists, #fists.Combo + 1)
			end).to.throw()
		end)

		it("leaves no move defaults on catalog definitions", function()
			for _, weapon in ipairs(Catalog.All()) do
				expect((weapon :: any).MoveDefaults).to.equal(nil)
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
