local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Support = script.Parent.Parent.support
local FakeRemote = require(Support.FakeRemote)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local LoadoutClient = require(StarterPlayer.StarterPlayerScripts.client.session.LoadoutClient)

local function make_loadout()
	local inventory_remote = FakeRemote.client()
	local weapon_remote = FakeRemote.client()
	local loadout = LoadoutClient.new({ inventory_remote = inventory_remote, weapon_remote = weapon_remote })
	return loadout, inventory_remote, weapon_remote
end

return function()
	describe("LoadoutClient", function()
		it("starts on the default weapon with an empty inventory", function()
			local loadout = make_loadout()
			expect(loadout.EquippedId).to.equal(Catalog.DefaultId)
			expect(#loadout.Entries).to.equal(0)
			expect(loadout.SelectedSlot).to.equal(0)
			loadout:Destroy()
		end)

		it("mirrors Weapon.Equipped and fires on every event", function()
			local loadout, _, weapon_remote = make_loadout()
			local fired = {}
			loadout.EquippedChanged:Connect(function(weapon_id)
				table.insert(fired, weapon_id)
			end)

			weapon_remote:Inject("Equipped", "Katana")
			weapon_remote:Inject("Equipped", "Katana")
			weapon_remote:Inject("Equipped", 5)
			weapon_remote:Inject("Other", "Fists")

			expect(loadout.EquippedId).to.equal("Katana")
			expect(#fired).to.equal(2)
			loadout:Destroy()
		end)

		it("stores a frozen copy of Inventory.Changed", function()
			local loadout, inventory_remote = make_loadout()
			local fired = {}
			loadout.InventoryChanged:Connect(function(entries, selected_slot)
				table.insert(fired, { entries, selected_slot })
			end)

			local payload = { { Slot = 2, Uid = "uid-katana", ItemId = "Katana" } }
			inventory_remote:Inject("Changed", payload, 2)

			expect(#fired).to.equal(1)
			expect(fired[1][2]).to.equal(2)
			expect(loadout.SelectedSlot).to.equal(2)
			expect(loadout.Entries[1].Uid).to.equal("uid-katana")
			expect(loadout.Entries[1].ItemId).to.equal("Katana")
			expect(loadout.Entries).never.to.equal(payload)
			expect(table.isfrozen(loadout.Entries)).to.equal(true)
			expect(table.isfrozen(loadout.Entries[1])).to.equal(true)
			loadout:Destroy()
		end)

		it("treats a missing selected slot as none and drops malformed payloads", function()
			local loadout, inventory_remote = make_loadout()
			inventory_remote:Inject("Changed", { { Slot = 2, Uid = "u", ItemId = "Katana" } }, nil)
			expect(loadout.SelectedSlot).to.equal(0)

			inventory_remote:Inject("Changed", { { Slot = "2", Uid = "u", ItemId = "Katana" } }, 2)
			-- The Phase 1 entry shape is no longer accepted.
			inventory_remote:Inject("Changed", { { Slot = 2, WeaponId = "Katana" } }, 2)
			inventory_remote:Inject("Changed", "nope", 2)
			expect(loadout.SelectedSlot).to.equal(0)
			expect(#loadout.Entries).to.equal(1)
			loadout:Destroy()
		end)

		it("validates inventory payload shapes", function()
			expect(LoadoutClient.is_valid_inventory({}, 0)).to.equal(true)
			expect(LoadoutClient.is_valid_inventory({ { Slot = 1, Uid = "u", ItemId = "Katana" } }, nil)).to.equal(true)
			expect(LoadoutClient.is_valid_inventory({ { Slot = 1, ItemId = "Katana" } }, 1)).to.equal(false)
			expect(LoadoutClient.is_valid_inventory({ { Slot = 1, Uid = "u" } }, 1)).to.equal(false)
			expect(LoadoutClient.is_valid_inventory(nil, 0)).to.equal(false)
			expect(LoadoutClient.is_valid_inventory({}, "1")).to.equal(false)
			expect(LoadoutClient.is_valid_inventory({ { Slot = 1 } }, 1)).to.equal(false)
		end)

		it("sends selection requests without changing local state", function()
			local loadout, inventory_remote = make_loadout()
			loadout:SelectSlot(3)
			loadout:SelectUid("uid-1")

			expect(#inventory_remote.Sent).to.equal(2)
			expect(inventory_remote.Sent[1][1]).to.equal("SelectSlot")
			expect(inventory_remote.Sent[1][2]).to.equal(3)
			expect(inventory_remote.Sent[2][1]).to.equal("SelectUid")
			expect(inventory_remote.Sent[2][2]).to.equal("uid-1")
			expect(loadout.SelectedSlot).to.equal(0)
			loadout:Destroy()
		end)

		it("selects a weapon through the lowest slot holding its item", function()
			local loadout, inventory_remote = make_loadout()
			inventory_remote:Inject("Changed", {
				{ Slot = 4, Uid = "uid-4", ItemId = "Katana" },
				{ Slot = 2, Uid = "uid-2", ItemId = "Katana" },
			}, 0)
			inventory_remote:Clear()

			expect(loadout:SelectWeapon("Katana")).to.equal(true)
			expect(inventory_remote.Sent[1][1]).to.equal("SelectUid")
			expect(inventory_remote.Sent[1][2]).to.equal("uid-2")
			loadout:Destroy()
		end)

		it("selects no slot for the default weapon and nothing for unowned weapons", function()
			local loadout, inventory_remote = make_loadout()

			expect(loadout:SelectWeapon(Catalog.DefaultId)).to.equal(true)
			expect(inventory_remote.Sent[1][1]).to.equal("SelectSlot")
			expect(inventory_remote.Sent[1][2]).to.equal(0)

			expect(loadout:SelectWeapon("Katana")).to.equal(false)
			expect(#inventory_remote.Sent).to.equal(1)
			loadout:Destroy()
		end)

		it("sends nothing after Destroy", function()
			local loadout, inventory_remote = make_loadout()
			loadout:Destroy()
			loadout:SelectSlot(1)
			loadout:SelectUid("u")
			expect(loadout:SelectWeapon(Catalog.DefaultId)).to.equal(false)
			expect(#inventory_remote.Sent).to.equal(0)
		end)
	end)
end
