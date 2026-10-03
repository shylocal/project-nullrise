local ServerScriptService = game:GetService("ServerScriptService")
local InventoryService = require(
	ServerScriptService:WaitForChild("server"):WaitForChild("services").InventoryService
)

return function()
	describe("InventoryService slot validation", function()
		it("exposes the maximum slot count", function()
			expect(typeof(InventoryService.MAX_SLOTS)).to.equal("number")
			expect(InventoryService.MAX_SLOTS >= 1).to.equal(true)
			expect(InventoryService.MAX_SLOTS % 1).to.equal(0)
		end)

		it("rejects invalid slot values when setting a slot", function()
			local invalid_slots = {
				0,
				-1,
				1.5,
				"1",
				math.huge,
				-math.huge,
				0 / 0,
				1e15,
				InventoryService.MAX_SLOTS + 1,
				true,
				{},
			}
			for _, slot in ipairs(invalid_slots) do
				local result = InventoryService.SetSlot({}, nil, slot, "Katana")
				expect(result).to.equal(false)
			end
		end)

		it("rejects invalid slot values when selecting a slot", function()
			local invalid_slots = {
				0,
				-1,
				1.5,
				"1",
				math.huge,
				0 / 0,
				1e15,
				InventoryService.MAX_SLOTS + 1,
				true,
			}
			for _, slot in ipairs(invalid_slots) do
				local result = InventoryService.SelectSlot({}, nil, slot)
				expect(result).to.equal(false)
			end
		end)

		it("rejects invalid item identifiers when selecting an item", function()
			local invalid_items = { nil, 1, "", string.rep("a", 65), {}, true }
			for index = 1, 6 do
				local result = InventoryService.SelectItem({}, nil, invalid_items[index])
				expect(result).to.equal(false)
			end
		end)

		it("accepts every slot within the slot range", function()
			local player = {}
			local inventory = {
				Slots = {},
				SelectedSlot = nil,
			}
			local service = setmetatable({
				Inventories = {
					[player] = inventory,
				},
				_sync = function() end,
				_replicate = function() end,
			}, InventoryService)

			local max_slots = InventoryService.MAX_SLOTS
			expect(service:SetSlot(player, max_slots, "Katana")).to.equal(true)
			expect(inventory.Slots[max_slots]).to.equal("Katana")

			expect(service:SelectSlot(player, max_slots)).to.equal(true)
			expect(inventory.SelectedSlot).to.equal(max_slots)
			expect(service:GetSlot(player, max_slots + 1)).to.equal(nil)
		end)

		it("does not give items beyond the last slot", function()
			local player = {}
			local slots = {}
			for slot = 1, InventoryService.MAX_SLOTS do
				slots[slot] = "Katana"
			end
			local service = setmetatable({
				Inventories = {
					[player] = {
						Slots = slots,
						SelectedSlot = nil,
					},
				},
				_sync = function() end,
				_replicate = function() end,
			}, InventoryService)

			expect(service:Give(player, "Katana")).to.equal(false)
			expect(slots[InventoryService.MAX_SLOTS + 1]).to.equal(nil)
		end)

		it("replicates a dense, slot-ordered entry list", function()
			local player = {}
			local inventory = {
				Slots = {
					[4] = "Fists",
					[2] = "Katana",
				},
				SelectedSlot = 2,
			}
			local service = setmetatable({
				Inventories = {
					[player] = inventory,
				},
			}, InventoryService)

			local snapshot = service:_get_replication_snapshot(player)
			expect(snapshot ~= nil).to.equal(true)
			if not snapshot then
				return
			end

			local entries = snapshot.Entries
			expect(#entries).to.equal(2)
			local count = 0
			for _ in pairs(entries) do
				count += 1
			end
			expect(count).to.equal(2)

			expect(entries[1].Slot).to.equal(2)
			expect(entries[1].WeaponId).to.equal("Katana")
			expect(entries[2].Slot).to.equal(4)
			expect(entries[2].WeaponId).to.equal("Fists")
			expect(snapshot.SelectedSlot).to.equal(2)
		end)

		it("replicates an integer selected slot when nothing is selected", function()
			local player = {}
			local service = setmetatable({
				Inventories = {
					[player] = {
						Slots = {},
						SelectedSlot = nil,
					},
				},
			}, InventoryService)

			local snapshot = service:_get_replication_snapshot(player)
			expect(snapshot ~= nil).to.equal(true)
			if not snapshot then
				return
			end

			expect(#snapshot.Entries).to.equal(0)
			expect(snapshot.SelectedSlot).to.equal(InventoryService.NO_SELECTION)
			expect(typeof(snapshot.SelectedSlot)).to.equal("number")
		end)

		it("returns a detached inventory replication snapshot", function()
			local player = {}
			local inventory = {
				Slots = {
					[2] = "Katana",
				},
				SelectedSlot = 2,
			}
			local service = setmetatable({
				Inventories = {
					[player] = inventory,
				},
			}, InventoryService)

			local public_view = service:Get(player)
			public_view.Entries[1].WeaponId = "Fists"
			table.insert(public_view.Entries, {
				Slot = 3,
				WeaponId = "Katana",
			})

			expect(inventory.Slots[2]).to.equal("Katana")
			expect(inventory.Slots[3]).to.equal(nil)
			expect(service:_get_replication_snapshot({})).to.equal(nil)
		end)

		it("throttles rapid selection requests across action types", function()
			local player = {}
			local now = os.clock()
			local service = setmetatable({
				Inventories = {
					[player] = {
						Slots = {
							[2] = "Katana",
						},
						SelectedSlot = nil,
					},
				},
				RemoteAt = {
					[player] = now,
				},
			}, InventoryService)

			expect(service:_allow_remote(player)).to.equal(false)
			service.RemoteAt[player] = now - 1
			expect(service:_allow_remote(player)).to.equal(true)
		end)

		it("rejects unknown weapon identifiers before accessing inventory state", function()
			local result = InventoryService.SetSlot({}, nil, 1, "MissingWeapon")
			expect(result).to.equal(false)
		end)
	end)
end
