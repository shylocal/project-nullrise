--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
local DataSchema = require(ReplicatedStorage.shared.data.Schema)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local PlayerDataService = require(ServerScriptService.server.services.PlayerDataService)
local InventoryService = require(ServerScriptService.server.services.InventoryService)
local ServerHarness = require(TestService.support.ServerHarness)
local FakeProfileStore = require(TestService.support.FakeProfileStore)

local DEFAULT_ID = Catalog.DefaultId
local MAX_SLOTS = InventoryService.MAX_SLOTS

-- The item these specs grant, and the weapon it equips.
local ITEM = ItemCatalog.Ids()[1]
local ITEM_WEAPON = (ItemCatalog.Get(ITEM) :: any).WeaponId

type Fixture = { h: any, store: any, data: any, inventory: any, player: any }

local function setup(): Fixture
	local h = ServerHarness.new()
	local store = FakeProfileStore.new(DataSchema.Template())
	h.Runtime:Add("PlayerDataService", function(get: (string) -> any)
		return PlayerDataService.new({
			players = get("PlayerService"),
			store = store,
			is_studio = false,
			config = Config.Data,
			telemetry = get("Telemetry"),
		})
	end)
	h.Runtime:Add("InventoryService", function(get: (string) -> any)
		return InventoryService.new({
			players = get("PlayerService"),
			data = get("PlayerDataService"),
			remote = h.Remotes.Inventory,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)
	h:Start()
	return {
		h = h,
		store = store,
		data = h:Get("PlayerDataService"),
		inventory = h:Get("InventoryService"),
		player = h.Players:Add(),
	}
end

local function last_changed(f: Fixture): any
	local sent = f.h.Remotes.Inventory.Sent
	return sent[#sent]
end

local function uid_in(f: Fixture, slot: number): string?
	for _, entry in f.inventory:Get(f.player).Entries do
		if entry.Slot == slot then
			return entry.Uid
		end
	end
	return nil
end

local function clear(f: Fixture)
	for _, entry in f.inventory:Get(f.player).Entries do
		f.inventory:RemoveUid(f.player, entry.Uid)
	end
end

return function()
	describe("InventoryService", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		it("exposes the configured slot count", function()
			expect(MAX_SLOTS).to.equal(Config.Inventory.MaxSlots)
		end)

		it("replicates the seeded Starter loadout on join with nothing selected", function()
			local snapshot = f.inventory:Get(f.player)
			for slot, weapon_id in Catalog.Loadout("Starter") do
				local found = false
				for _, entry in snapshot.Entries do
					if entry.Slot == slot then
						found = true
						expect(entry.ItemId).to.equal((ItemCatalog.ForWeapon(weapon_id) :: any).Id)
						expect(typeof(entry.Uid)).to.equal("string")
					end
				end
				expect(found).to.equal(true)
			end
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(DEFAULT_ID)
			expect(f.inventory:GetSelected(f.player)).to.equal(nil)

			local packet = last_changed(f)
			expect(packet[1]).to.equal(f.player)
			expect(packet[2]).to.equal(Protocol.Inventory.Changed)
			expect(typeof(packet[3])).to.equal("table")
			expect(packet[4]).to.equal(InventoryService.NO_SELECTION)
		end)

		it("fires Changed only once the session is Ready", function()
			local changes = {}
			f.inventory.Changed:Connect(function(player, weapon_id, selected_slot)
				table.insert(changes, { player, weapon_id, selected_slot })
			end)

			local other = f.h.Players:Add()
			expect(#changes).to.equal(0)

			f.inventory:SelectSlot(other, 2)
			expect(#changes).to.equal(1)
			expect(changes[1][1]).to.equal(other)
			expect(changes[1][3]).to.equal(2)

			f.inventory:SelectSlot(other, 2)
			expect(changes[2][2]).to.equal(DEFAULT_ID)
			expect(changes[2][3]).to.equal(InventoryService.NO_SELECTION)
		end)

		it("writes items straight into the profile data", function()
			clear(f)
			local uid = f.inventory:Grant(f.player, ITEM, 5)
			expect(uid).to.be.ok()

			local record = f.data:GetData(f.player).Inventory.Slots["5"]
			expect(record.Uid).to.equal(uid)
			expect(record.ItemId).to.equal(ITEM)
			expect(typeof(record.Data)).to.equal("table")
		end)

		it("grants into the first empty slot and refuses when full", function()
			clear(f)
			for slot = 1, MAX_SLOTS do
				expect(f.inventory:Grant(f.player, ITEM)).to.be.ok()
				expect(uid_in(f, slot)).to.be.ok()
			end
			expect(f.inventory:Grant(f.player, ITEM)).to.equal(nil)
		end)

		it("gives every grant a unique uid", function()
			clear(f)
			local a = f.inventory:Grant(f.player, ITEM)
			local b = f.inventory:Grant(f.player, ITEM)
			expect(a).never.to.equal(b)
		end)

		it("rejects invalid grants", function()
			clear(f)
			local invalid_slots: { any } = { 0, -1, 1.5, "1", math.huge, 0 / 0, MAX_SLOTS + 1, true }
			for _, slot in invalid_slots do
				expect(f.inventory:Grant(f.player, ITEM, slot)).to.equal(nil)
			end

			expect(f.inventory:Grant(f.player, "MissingItem")).to.equal(nil)
			expect(f.inventory:Grant(f.player, DEFAULT_ID)).to.equal(nil)
			expect(f.inventory:Grant(f.player, 5)).to.equal(nil)

			f.inventory:Grant(f.player, ITEM, 3)
			expect(f.inventory:Grant(f.player, ITEM, 3)).to.equal(nil)
			expect(#f.inventory:Get(f.player).Entries).to.equal(1)
		end)

		it("rejects invalid slot values when selecting a slot", function()
			local invalid_slots: { any } = { -1, 1.5, "1", math.huge, 0 / 0, 1e15, MAX_SLOTS + 1, true }
			for _, slot in invalid_slots do
				expect(f.inventory:SelectSlot(f.player, slot)).to.equal(false)
			end
		end)

		it("treats slot 0 as selecting nothing", function()
			expect(f.inventory:SelectSlot(f.player, 2)).to.equal(true)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(2)

			expect(f.inventory:SelectSlot(f.player, InventoryService.NO_SELECTION)).to.equal(true)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(nil)
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(DEFAULT_ID)
		end)

		it("toggles back to nothing when the selected slot is selected again", function()
			f.inventory:SelectSlot(f.player, 2)
			f.inventory:SelectSlot(f.player, 2)

			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(nil)
		end)

		it("rejects invalid and unknown uids", function()
			local invalid: { any } = { 1, "", string.rep("a", Config.Inventory.MaxItemIdLength + 1), {}, true, "missing-uid" }
			expect(f.inventory:SelectUid(f.player, nil)).to.equal(false)
			for _, uid in invalid do
				expect(f.inventory:SelectUid(f.player, uid)).to.equal(false)
				expect(f.inventory:RemoveUid(f.player, uid)).to.equal(false)
			end
		end)

		it("selects an owned item by uid", function()
			clear(f)
			local uid = f.inventory:Grant(f.player, ITEM, 4)

			expect(f.inventory:SelectUid(f.player, uid)).to.equal(true)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(4)
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(ITEM_WEAPON)

			local selected = f.inventory:GetSelected(f.player)
			expect(selected.Uid).to.equal(uid)
			expect(selected.ItemId).to.equal(ITEM)

			-- Selecting it again toggles back to the default weapon.
			expect(f.inventory:SelectUid(f.player, uid)).to.equal(true)
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(DEFAULT_ID)
		end)

		it("equips the default weapon from an empty selected slot", function()
			clear(f)
			expect(f.inventory:SelectSlot(f.player, 6)).to.equal(true)
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(DEFAULT_ID)

			local changed = nil
			f.inventory.Changed:Connect(function(_player, weapon_id)
				changed = weapon_id
			end)
			f.inventory:Grant(f.player, ITEM, 6)
			expect(changed).to.equal(ITEM_WEAPON)
		end)

		it("re-announces when the selected item is removed", function()
			clear(f)
			local uid = f.inventory:Grant(f.player, ITEM, 1)
			f.inventory:SelectUid(f.player, uid)

			local changed = nil
			f.inventory.Changed:Connect(function(_player, weapon_id)
				changed = weapon_id
			end)

			expect(f.inventory:RemoveUid(f.player, uid)).to.equal(true)
			expect(changed).to.equal(DEFAULT_ID)
			expect(f.data:GetData(f.player).Inventory.Slots["1"]).to.equal(nil)
		end)

		it("replicates a dense, slot-ordered entry list", function()
			clear(f)
			local four = f.inventory:Grant(f.player, ITEM, 4)
			local two = f.inventory:Grant(f.player, ITEM, 2)
			f.inventory:SelectSlot(f.player, 2)

			local snapshot = f.inventory:Get(f.player)
			local entries = snapshot.Entries
			expect(#entries).to.equal(2)
			local count = 0
			for _ in pairs(entries) do
				count += 1
			end
			expect(count).to.equal(2)
			expect(entries[1].Slot).to.equal(2)
			expect(entries[1].Uid).to.equal(two)
			expect(entries[2].Slot).to.equal(4)
			expect(entries[2].Uid).to.equal(four)
			expect(entries[1].ItemId).to.equal(ITEM)
			expect(snapshot.SelectedSlot).to.equal(2)

			local packet = last_changed(f)
			expect(#packet[3]).to.equal(2)
			expect(packet[4]).to.equal(2)
		end)

		it("replicates an integer selected slot when nothing is selected", function()
			local snapshot = f.inventory:Get(f.player)

			expect(snapshot.SelectedSlot).to.equal(InventoryService.NO_SELECTION)
			expect(typeof(snapshot.SelectedSlot)).to.equal("number")
		end)

		it("returns detached views", function()
			local public_view = f.inventory:Get(f.player)
			local slot = public_view.Entries[1].Slot
			public_view.Entries[1].ItemId = "MissingItem"
			table.insert(public_view.Entries, { Slot = 3, Uid = "x", ItemId = ITEM })

			local slots = f.data:GetData(f.player).Inventory.Slots
			expect(slots[tostring(slot)].ItemId).to.equal(ITEM)
			expect(slots["3"]).to.equal(nil)
			expect(f.inventory:Get({})).to.equal(nil)

			f.inventory:SelectSlot(f.player, slot)
			local selected = f.inventory:GetSelected(f.player)
			selected.Data.Mutated = true
			expect(slots[tostring(slot)].Data.Mutated).to.equal(nil)
		end)

		it("handles remote selection for Ready players within the budget", function()
			local remote = f.h.Remotes.Inventory

			remote:Inject(f.player, Protocol.Inventory.SelectSlot, 2)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(2)

			remote:Inject(f.player, Protocol.Inventory.SelectSlot, 0)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(nil)

			local uid = uid_in(f, 2)
			remote:Inject(f.player, Protocol.Inventory.SelectUid, uid)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(2)

			-- Burst requests beyond the budget are dropped.
			local burst = Config.Network.RemoteBudget.Actions["Inventory.SelectSlot"].Burst
			for _ = 1, burst + 5 do
				remote:Inject(f.player, Protocol.Inventory.SelectSlot, 2)
			end
			local snapshot = f.h:Get("Telemetry"):Snapshot()
			expect((snapshot["Network.RateLimited.Inventory.SelectSlot"] or 0) > 0).to.equal(true)

			remote:Inject(f.player, 7)
			expect(f.h:Get("Telemetry"):Snapshot()["Network.BadPayload.Inventory"]).to.equal(1)
		end)

		it("ignores the removed SelectItem action", function()
			f.h.Remotes.Inventory:Inject(f.player, "SelectItem", ITEM_WEAPON)

			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(nil)
			expect(f.h:Get("Telemetry"):Snapshot()["Network.UnknownAction.Inventory.<unknown>"]).to.equal(1)
		end)

		it("has no inventory for a player whose data failed to load", function()
			local key = Config.Data.KeyPrefix .. "777"
			f.store.Fail[key] = true
			local kicked = f.h.Players:Add({ UserId = 777 })

			expect(kicked.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.inventory:Get(kicked)).to.equal(nil)
			expect(f.inventory:Grant(kicked, ITEM)).to.equal(nil)
			expect(f.inventory:SelectSlot(kicked, 1)).to.equal(false)
			expect(f.inventory:GetEquippedWeaponId(kicked)).to.equal(DEFAULT_ID)
		end)

		it("keeps records this build does not recognise, without exposing them", function()
			-- Regression: they used to be deleted on load and the deletion saved.
			local key = Config.Data.KeyPrefix .. "888"
			f.store.Saved[key] = {
				Version = DataSchema.Version,
				Inventory = {
					Seeded = true,
					Slots = {
						["1"] = { Uid = "known", ItemId = ITEM, Data = {} },
						["2"] = { Uid = "future-item", ItemId = "FutureItem", Data = { Level = 3 } },
						[tostring(MAX_SLOTS + 1)] = { Uid = "future-slot", ItemId = ITEM, Data = {} },
					},
				},
			}
			local player = f.h.Players:Add({ UserId = 888 })

			-- Only the known record in a known slot is replicated.
			local entries = f.inventory:Get(player).Entries
			expect(#entries).to.equal(1)
			expect(entries[1].Uid).to.equal("known")

			-- The unknown item's slot equips the default weapon, exposes no
			-- record and is never overwritten by a grant.
			expect(f.inventory:SelectSlot(player, 2)).to.equal(true)
			expect(f.inventory:GetEquippedWeaponId(player)).to.equal(DEFAULT_ID)
			expect(f.inventory:GetSelected(player)).to.equal(nil)
			expect(f.inventory:Grant(player, ITEM, 2)).to.equal(nil)
			local granted = f.inventory:Grant(player, ITEM)
			expect(granted).to.be.ok()
			expect(f.data:GetData(player).Inventory.Slots["3"].Uid).to.equal(granted)

			-- Both are saved as they were.
			f.h.Players:Remove(player)
			local saved = f.store.Saved[key].Inventory.Slots
			expect(saved["2"].ItemId).to.equal("FutureItem")
			expect(saved["2"].Data.Level).to.equal(3)
			expect(saved[tostring(MAX_SLOTS + 1)].Uid).to.equal("future-slot")
		end)

		it("keeps items across sessions and resets the selection", function()
			f.inventory:SelectSlot(f.player, 2)
			local uid = uid_in(f, 2)
			local user_id = f.player.UserId

			f.h.Players:Remove(f.player)
			expect(f.inventory:Get(f.player)).to.equal(nil)
			expect(f.inventory:GetEquippedWeaponId(f.player)).to.equal(DEFAULT_ID)
			expect(f.inventory:SelectSlot(f.player, 2)).to.equal(false)

			f.player = f.h.Players:Add({ UserId = user_id })
			expect(uid_in(f, 2)).to.equal(uid)
			expect(f.inventory:GetSelectedSlot(f.player)).to.equal(nil)
		end)
	end)
end
