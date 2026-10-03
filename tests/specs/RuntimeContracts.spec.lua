local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

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

		it("resolves built-in weapon bindings and hitboxes in their model templates", function()
			local weapon_models = ReplicatedStorage:WaitForChild("weapon_models")

			for _, weapon_id in ipairs({ "Fists", "Katana" }) do
				local weapon = Catalog.Get(weapon_id)
				expect(typeof(weapon)).to.equal("table")
				if not weapon then
					continue
				end

				local model = weapon_models:FindFirstChild(weapon.Model)
				expect(model ~= nil).to.equal(true)
				if not model then
					continue
				end

				for wield_name in pairs(weapon.Wield or {}) do
					local wielded = model:FindFirstChild(wield_name, true)
					expect(wielded ~= nil and wielded:IsA("BasePart")).to.equal(true)
				end

				local function expect_hitbox(attack)
					local hitbox = model:FindFirstChild(attack.Hitbox, true)
					expect(hitbox ~= nil and hitbox:IsA("BasePart")).to.equal(true)
				end

				for _, attack in pairs(weapon.Attacks or {}) do
					expect_hitbox(attack)
				end

				if weapon.Charge then
					expect_hitbox(weapon.Charge)
				end
			end
		end)

		it("loads client controller modules and exposes constructors", function()
			local client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
			local controllers = client:WaitForChild("controllers")
			local names = {
				"AnimationController",
				"CharacterController",
				"CombatController",
				"InputController",
				"MovementController",
				"ParkourController",
				"PlayerController",
				"UIController",
				"WeaponController",
			}

			for _, name in ipairs(names) do
				local module = controllers:FindFirstChild(name)
				expect(module ~= nil and module:IsA("ModuleScript")).to.equal(true)
				if module then
					local exported = require(module)
					expect(typeof(exported)).to.equal("table")
					expect(typeof(exported.new)).to.equal("function")
				end
			end
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
				{ "MovementValidation", "ClassifyDelta" },
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
