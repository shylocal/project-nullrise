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

		it("rejects unknown weapon identifiers before accessing inventory state", function()
			local result = InventoryService.SetSlot({}, nil, 1, "MissingWeapon")
			expect(result).to.equal(false)
		end)
	end)
end
