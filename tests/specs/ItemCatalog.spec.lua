--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)

local function has_error(errors: { string }, fragment: string): boolean
	for _, message in errors do
		if string.find(message, fragment, 1, true) then
			return true
		end
	end
	return false
end

return function()
	describe("ItemCatalog", function()
		it("lists sorted, frozen item ids", function()
			local ids = ItemCatalog.Ids()
			expect(#ids > 0).to.equal(true)
			expect(table.isfrozen(ids)).to.equal(true)
			for index = 2, #ids do
				expect(ids[index - 1] < ids[index]).to.equal(true)
			end
		end)

		it("injects Id and freezes every item", function()
			for _, id in ItemCatalog.Ids() do
				local item = ItemCatalog.Get(id) :: any
				expect(item).to.be.ok()
				expect(item.Id).to.equal(id)
				expect(table.isfrozen(item)).to.equal(true)
			end
			expect(ItemCatalog.Get("MissingItem")).to.equal(nil)
			expect(ItemCatalog.Get(5)).to.equal(nil)
		end)

		it("maps every item to an equippable, non-default weapon", function()
			for _, id in ItemCatalog.Ids() do
				local item = ItemCatalog.Get(id) :: any
				expect(item.Kind).to.equal("Weapon")
				expect(Catalog.IsEquippable(Catalog.Get(item.WeaponId))).to.equal(true)
				expect(item.WeaponId).never.to.equal(Catalog.DefaultId)
				expect(ItemCatalog.ForWeapon(item.WeaponId)).to.be.ok()
			end
		end)

		it("never turns the default weapon into an item", function()
			expect(ItemCatalog.ForWeapon(Catalog.DefaultId)).to.equal(nil)
			expect(ItemCatalog.ForWeapon(nil)).to.equal(nil)
		end)

		it("keeps today's Katana item", function()
			local katana = ItemCatalog.Get("Katana") :: any
			expect(katana).to.be.ok()
			expect(katana.WeaponId).to.equal("Katana")
			expect(katana.Stackable).to.equal(false)
		end)

		it("has an item for every Starter loadout weapon", function()
			for _, weapon_id in Catalog.Loadout("Starter") do
				expect(ItemCatalog.ForWeapon(weapon_id)).to.be.ok()
			end
		end)

		it("collects every error in a broken item table", function()
			local errors = ItemCatalog.check({
				Good = { Kind = "Weapon", WeaponId = "Katana", Stackable = false },
				BadKind = { Kind = "Potion", WeaponId = "Katana", Stackable = false },
				Default = { Kind = "Weapon", WeaponId = Catalog.DefaultId, Stackable = false },
				Unknown = { Kind = "Weapon", WeaponId = "MissingWeapon", Stackable = false },
				Extra = { Kind = "Weapon", WeaponId = "Katana", Stackable = false, Color = "red" },
				["1bad"] = { Kind = "Weapon", WeaponId = "Katana", Stackable = false },
			})

			expect(#errors).to.equal(5)
			expect(has_error(errors, "Items.BadKind.Kind")).to.equal(true)
			expect(has_error(errors, "Items.Default.WeaponId: must not be the default weapon")).to.equal(true)
			expect(has_error(errors, "Items.Unknown.WeaponId")).to.equal(true)
			expect(has_error(errors, "Items.Extra.Color: unknown key")).to.equal(true)
			expect(has_error(errors, "Items.1bad")).to.equal(true)
			expect(#ItemCatalog.check("items")).to.equal(1)
		end)
	end)
end
