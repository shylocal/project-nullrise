local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

return function()
	describe("Studio runtime contracts", function()
		it("has the configured remotes and shared packages", function()
			local remotes = ReplicatedStorage:FindFirstChild("remotes")
			expect(remotes ~= nil).to.equal(true)
			for _, name in ipairs({ "Combat", "Weapon", "Inventory" }) do
				local remote = remotes:FindFirstChild(name)
				expect(remote ~= nil).to.equal(true)
				if remote then
					expect(remote:IsA("RemoteEvent")).to.equal(true)
				end
			end

			local packages = ReplicatedStorage:FindFirstChild("packages")
			expect(packages ~= nil).to.equal(true)
			if packages then
				expect(packages:FindFirstChild("Trove") ~= nil).to.equal(true)
				expect(packages:FindFirstChild("Signal") ~= nil).to.equal(true)
				expect(packages:FindFirstChild("TestEZ") ~= nil).to.equal(true)
			end
			expect(ReplicatedStorage:FindFirstChild("weapon_models") ~= nil).to.equal(true)
		end)

		it("loads server modules and exposes their public entrypoints", function()
			local server = ServerScriptService:WaitForChild("server")
			local services = server:WaitForChild("services")
			local expectations = {
				{ "CombatService", "new" },
				{ "CombatValidation", "ValidateHit" },
				{ "InventoryService", "SetSlot" },
				{ "PlayerService", "Get" },
				{ "PlayerSession", "Destroy" },
				{ "WeaponAttachment", "Attach" },
				{ "WeaponService", "Equip" },
			}

			for _, expectation in ipairs(expectations) do
				local module = services:FindFirstChild(expectation[1])
				expect(module ~= nil and module:IsA("ModuleScript")).to.equal(true)
				if module then
					local exported = require(module)
					expect(typeof(exported)).to.equal("table")
					expect(typeof(exported[expectation[2]])).to.equal("function")
				end
			end
		end)
	end)
end
