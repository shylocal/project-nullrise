local ServerScriptService = game:GetService("ServerScriptService")
local InventoryService = require(
	ServerScriptService:WaitForChild("server"):WaitForChild("services").InventoryService
)

return function()
	describe("InventoryService slot validation", function()
		it("rejects invalid slot values when setting a slot", function()
			local invalid_slots = { 0, -1, 1.5, "1", math.huge, 0 / 0 }
			for _, slot in ipairs(invalid_slots) do
				local result = InventoryService.SetSlot({}, nil, slot, "Katana")
				expect(result).to.equal(false)
			end
		end)

		it("rejects invalid slot values when selecting a slot", function()
			local invalid_slots = { 0, -1, 1.5, "1", math.huge, 0 / 0 }
			for _, slot in ipairs(invalid_slots) do
				local result = InventoryService.SelectSlot({}, nil, slot)
				expect(result).to.equal(false)
			end
		end)

		it("accepts positive integer slots beyond the current keyboard bindings", function()
			local player = {}
			local inventory = {
				Slots = {},
				SelectedSlot = 128,
			}
			local service = setmetatable({
				Inventories = {
					[player] = inventory,
				},
				_sync = function() end,
			}, InventoryService)

			local set_result = service:SetSlot(player, 128, "Katana")
			expect(set_result).to.equal(true)
			expect(inventory.Slots[128]).to.equal("Katana")

			local select_result = service:SelectSlot(player, 256)
			expect(select_result).to.equal(true)
			expect(inventory.SelectedSlot).to.equal(256)
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

			local snapshot = service:_get_replication_snapshot(player)
			expect(snapshot ~= nil).to.equal(true)
			if not snapshot then
				return
			end

			expect(snapshot.Slots ~= inventory.Slots).to.equal(true)
			expect(snapshot.SelectedSlot).to.equal(2)

			local public_view = service:Get(player)
			expect(public_view.Slots ~= inventory.Slots).to.equal(true)
			public_view.Slots[2] = "Fists"
			expect(inventory.Slots[2]).to.equal("Katana")

			snapshot.Slots[2] = "Fists"
			snapshot.Slots[3] = "Katana"

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
