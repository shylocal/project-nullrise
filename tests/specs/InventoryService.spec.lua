--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local InventoryService = require(ServerScriptService.server.services.InventoryService)
local ServerHarness = require(TestService.support.ServerHarness)

local DEFAULT_ID = Catalog.DefaultId
local MAX_SLOTS = InventoryService.MAX_SLOTS

-- The first equippable, non-default weapon id: the item used by these specs.
local function item_id(): string
	for _, id in Catalog.Ids() do
		if id ~= DEFAULT_ID then
			return id
		end
	end
	error("the catalog has no item weapon")
end

local ITEM = item_id()

local function setup(): (any, any, any)
	local h = ServerHarness.new()
	h.Runtime:Add("InventoryService", function(get)
		return InventoryService.new({
			players = get("PlayerService"),
			remote = h.Remotes.Inventory,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)
	h:Start()
	return h, h:Get("InventoryService"), h.Players:Add()
end

local function last_changed(h: any): any
	local sent = h.Remotes.Inventory.Sent
	return sent[#sent]
end

return function()
	describe("InventoryService", function()
		local h: any
		local inventory: any
		local player: any

		beforeEach(function()
			h, inventory, player = setup()
		end)

		afterEach(function()
			h:Destroy()
		end)

		it("exposes the configured slot count", function()
			expect(MAX_SLOTS).to.equal(Config.Inventory.MaxSlots)
		end)

		it("seeds the Starter loadout and replicates it on join", function()
			local loadout = Catalog.Loadout("Starter")
			for slot, weapon_id in loadout do
				expect(inventory:GetSlot(player, slot)).to.equal(weapon_id)
			end
			expect(inventory:GetSelectedId(player)).to.equal(DEFAULT_ID)

			local packet = last_changed(h)
			expect(packet[1]).to.equal(player)
			expect(packet[2]).to.equal(Protocol.Inventory.Changed)
			expect(typeof(packet[3])).to.equal("table")
			expect(packet[4]).to.equal(InventoryService.NO_SELECTION)
		end)

		it("fires Changed only once the session is Ready", function()
			local changes = 0
			inventory.Changed:Connect(function()
				changes += 1
			end)

			local other = h.Players:Add()
			expect(changes).to.equal(0)

			inventory:SelectSlot(other, 2)
			expect(changes).to.equal(1)
		end)

		it("rejects invalid slot values when setting a slot", function()
			local invalid_slots: { any } = { 0, -1, 1.5, "1", math.huge, -math.huge, 0 / 0, 1e15, MAX_SLOTS + 1, true, {} }
			for _, slot in invalid_slots do
				expect(inventory:SetSlot(player, slot, ITEM)).to.equal(false)
			end
		end)

		it("rejects invalid slot values when selecting a slot", function()
			local invalid_slots: { any } = { -1, 1.5, "1", math.huge, 0 / 0, 1e15, MAX_SLOTS + 1, true }
			for _, slot in invalid_slots do
				expect(inventory:SelectSlot(player, slot)).to.equal(false)
			end
		end)

		it("treats slot 0 as selecting nothing", function()
			expect(inventory:SelectSlot(player, 2)).to.equal(true)
			expect(inventory:GetSelectedSlot(player)).to.equal(2)

			expect(inventory:SelectSlot(player, InventoryService.NO_SELECTION)).to.equal(true)
			expect(inventory:GetSelectedSlot(player)).to.equal(nil)
			expect(inventory:GetSelectedId(player)).to.equal(DEFAULT_ID)
		end)

		it("toggles back to nothing when the selected slot is selected again", function()
			inventory:SelectSlot(player, 2)
			inventory:SelectSlot(player, 2)

			expect(inventory:GetSelectedSlot(player)).to.equal(nil)
		end)

		it("rejects invalid item identifiers when selecting an item", function()
			local invalid_items: { any } = { 1, "", string.rep("a", Config.Inventory.MaxItemIdLength + 1), {}, true }
			expect(inventory:SelectItem(player, nil)).to.equal(false)
			for _, item in invalid_items do
				expect(inventory:SelectItem(player, item)).to.equal(false)
			end
		end)

		it("selects an owned item and the default weapon by id", function()
			inventory:SetSlot(player, 4, ITEM)
			inventory:SetSlot(player, 2, nil)

			expect(inventory:SelectItem(player, ITEM)).to.equal(true)
			expect(inventory:GetSelectedSlot(player)).to.equal(4)
			expect(inventory:GetSelectedId(player)).to.equal(ITEM)

			expect(inventory:SelectItem(player, DEFAULT_ID)).to.equal(true)
			expect(inventory:GetSelectedSlot(player)).to.equal(nil)
		end)

		it("accepts every slot within the slot range", function()
			expect(inventory:SetSlot(player, MAX_SLOTS, ITEM)).to.equal(true)
			expect(inventory:GetSlot(player, MAX_SLOTS)).to.equal(ITEM)

			expect(inventory:SelectSlot(player, MAX_SLOTS)).to.equal(true)
			expect(inventory:GetSelectedSlot(player)).to.equal(MAX_SLOTS)
			expect(inventory:GetSlot(player, MAX_SLOTS + 1)).to.equal(nil)
		end)

		it("does not give items beyond the last slot", function()
			for slot = 1, MAX_SLOTS do
				inventory:SetSlot(player, slot, ITEM)
			end

			expect(inventory:Give(player, ITEM)).to.equal(false)
			expect(inventory:GetSlot(player, MAX_SLOTS + 1)).to.equal(nil)
		end)

		it("never stores the default weapon in a slot", function()
			expect(inventory:SetSlot(player, 3, DEFAULT_ID)).to.equal(true)
			expect(inventory:GetSlot(player, 3)).to.equal(nil)
			expect(inventory:Has(player, DEFAULT_ID)).to.equal(true)
		end)

		it("rejects unknown weapon identifiers", function()
			expect(inventory:SetSlot(player, 1, "MissingWeapon")).to.equal(false)
			expect(inventory:GetSlot(player, 1)).to.equal(nil)
		end)

		it("replicates a dense, slot-ordered entry list", function()
			for slot = 1, MAX_SLOTS do
				inventory:SetSlot(player, slot, nil)
			end
			inventory:SetSlot(player, 4, ITEM)
			inventory:SetSlot(player, 2, ITEM)
			inventory:SelectSlot(player, 2)

			local snapshot = inventory:Get(player)
			local entries = snapshot.Entries
			expect(#entries).to.equal(2)
			local count = 0
			for _ in pairs(entries) do
				count += 1
			end
			expect(count).to.equal(2)
			expect(entries[1].Slot).to.equal(2)
			expect(entries[2].Slot).to.equal(4)
			expect(entries[1].WeaponId).to.equal(ITEM)
			expect(snapshot.SelectedSlot).to.equal(2)

			local packet = last_changed(h)
			expect(#packet[3]).to.equal(2)
			expect(packet[4]).to.equal(2)
		end)

		it("replicates an integer selected slot when nothing is selected", function()
			local snapshot = inventory:Get(player)

			expect(snapshot.SelectedSlot).to.equal(InventoryService.NO_SELECTION)
			expect(typeof(snapshot.SelectedSlot)).to.equal("number")
		end)

		it("returns a detached inventory snapshot", function()
			local public_view = inventory:Get(player)
			public_view.Entries[1].WeaponId = DEFAULT_ID
			table.insert(public_view.Entries, { Slot = 3, WeaponId = ITEM })

			expect(inventory:GetSlot(player, public_view.Entries[1].Slot)).to.equal(ITEM)
			expect(inventory:GetSlot(player, 3)).to.equal(nil)
			expect(inventory:Get({})).to.equal(nil)
		end)

		it("handles remote selection for Ready players within the budget", function()
			local remote = h.Remotes.Inventory

			remote:Inject(player, Protocol.Inventory.SelectSlot, 2)
			expect(inventory:GetSelectedSlot(player)).to.equal(2)

			-- Burst requests beyond the budget are dropped.
			local burst = Config.Network.RemoteBudget.Actions["Inventory.SelectSlot"].Burst
			for _ = 1, burst + 5 do
				remote:Inject(player, Protocol.Inventory.SelectSlot, 2)
			end
			local snapshot = h:Get("Telemetry"):Snapshot()
			expect((snapshot["Network.RateLimited.Inventory.SelectSlot"] or 0) > 0).to.equal(true)

			remote:Inject(player, 7)
			expect(h:Get("Telemetry"):Snapshot()["Network.BadPayload.Inventory"]).to.equal(1)
		end)

		it("drops all state when the player leaves", function()
			h.Players:Remove(player)

			expect(inventory:Get(player)).to.equal(nil)
			expect(inventory:GetSelectedId(player)).to.equal(DEFAULT_ID)
			expect(inventory:SelectSlot(player, 2)).to.equal(false)
		end)
	end)
end
