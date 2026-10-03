local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Trove = require(ReplicatedStorage.packages.Trove)

-- Specs must never yield indefinitely, so every lookup uses FindFirstChild.
-- ServerStorage and ServerScriptService are empty when viewed from a client.
local IS_SERVER = RunService:IsServer()

local function find_controller(name)
	local player_scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local client = player_scripts and player_scripts:FindFirstChild("client")
	local controllers = client and client:FindFirstChild("controllers")
	return controllers and controllers:FindFirstChild(name)
end

local function find_ui_module(name)
	local ui = find_controller("UIController")
	return ui and ui:FindFirstChild(name)
end

-- PlayerController with character construction stubbed out, so only the
-- Workspace-parenting wait is exercised.
local function make_player_controller(PlayerController, created)
	return setmetatable({
		Player = { Parent = Players },
		Trove = Trove.new(),
		CharacterController = nil,
		PendingCharacter = nil,
		PendingTrove = nil,
		UIController = nil,
		_destroyed = false,
		_create_character_controller = function(_, character)
			table.insert(created, character)
		end,
	}, PlayerController)
end

-- Stands in for UIController so UI modules can be built without PlayerGui.
local function make_ui_controller(templates)
	return {
		CloneTemplate = function(_, name)
			return templates[name]
		end,
	}
end

local function make_weapon_button(parent, weapon_id)
	local button = Instance.new("TextButton")
	button.Name = weapon_id
	button:SetAttribute("WeaponId", weapon_id)
	local selection = Instance.new("Frame")
	selection.Name = "Selection"
	selection.Visible = false
	selection.Parent = button
	button.Parent = parent
	return button, selection
end

return function()
	describe("Studio runtime contracts", function()
		it("has the configured remotes and shared packages", function()
			local remotes = ReplicatedStorage:FindFirstChild("remotes")
			expect(remotes ~= nil).to.equal(true)
			for _, name in ipairs({ "Combat", "Weapon", "Inventory" }) do
				local remote = remotes and remotes:FindFirstChild(name)
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
				-- TestEZ is test-only and lives under TestService, so it is never
				-- shipped to clients through ReplicatedStorage.packages.
				expect(packages:FindFirstChild("TestEZ")).to.equal(nil)
			end
			expect(game:GetService("TestService"):FindFirstChild("TestEZ") ~= nil).to.equal(true)
			-- UI templates are optional content, but the folder itself is part of the project tree.
			expect(ReplicatedStorage:FindFirstChild("ui") ~= nil).to.equal(true)
		end)

		it("keeps weapon model templates in ServerStorage", function()
			if not IS_SERVER then
				return
			end
			expect(ServerStorage:FindFirstChild("weapon_models") ~= nil).to.equal(true)
		end)

		it("resolves built-in weapon bindings and hitboxes in their model templates", function()
			if not IS_SERVER then
				return
			end

			local weapon_models = ServerStorage:FindFirstChild("weapon_models")
			expect(weapon_models ~= nil).to.equal(true)
			if not weapon_models then
				return
			end

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

				for _, attack in ipairs(weapon.Attacks) do
					expect_hitbox(attack)
				end

				if weapon.Charge then
					expect_hitbox(weapon.Charge)
				end
			end
		end)

		it("loads client controller modules and exposes constructors", function()
			local player_scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
			local client = player_scripts and player_scripts:FindFirstChild("client")
			local controllers = client and client:FindFirstChild("controllers")
			expect(controllers ~= nil).to.equal(true)
			if not controllers then
				return
			end
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
			if not IS_SERVER then
				return
			end

			local server = ServerScriptService:FindFirstChild("server")
			local services = server and server:FindFirstChild("services")
			expect(services ~= nil).to.equal(true)
			if not services then
				return
			end
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

		it("runs UI modules as no-ops when their templates are missing", function()
			local weapon_menu_module = find_ui_module("WeaponMenu")
			local hitmarker_module = find_ui_module("Hitmarker")
			expect(weapon_menu_module ~= nil).to.equal(true)
			expect(hitmarker_module ~= nil).to.equal(true)
			if not weapon_menu_module or not hitmarker_module then
				return
			end

			local ui_controller = make_ui_controller({})

			local menu = require(weapon_menu_module).new(ui_controller)
			expect(menu.Gui).to.equal(nil)
			menu:SetInventory({ { Slot = 2, WeaponId = "Katana" } }, 2)
			menu:SetEquipped("Katana")
			expect(menu.SelectedWeapon).to.equal(nil)
			menu:Destroy()

			local hitmarker = require(hitmarker_module).new(ui_controller)
			expect(hitmarker.Gui).to.equal(nil)
			hitmarker:BindCharacter(nil)
			hitmarker:Show()
			hitmarker:Destroy()
		end)

		it("syncs WeaponMenu slots and selection from Inventory.Changed", function()
			local weapon_menu_module = find_ui_module("WeaponMenu")
			expect(weapon_menu_module ~= nil).to.equal(true)
			if not weapon_menu_module then
				return
			end

			local gui = Instance.new("ScreenGui")
			local fists_button, fists_selection = make_weapon_button(gui, "Fists")
			local katana_button, katana_selection = make_weapon_button(gui, "Katana")

			local menu = require(weapon_menu_module).new(make_ui_controller({ WeaponMenu = gui }))
			expect(menu.SelectedWeapon).to.equal("Fists")
			expect(fists_selection.Visible).to.equal(true)

			menu:SetInventory({ { Slot = 2, WeaponId = "Katana" } }, 2)
			expect(menu.SelectedWeapon).to.equal("Katana")
			expect(katana_button.Visible).to.equal(true)
			expect(katana_selection.Visible).to.equal(true)
			expect(fists_selection.Visible).to.equal(false)

			-- An empty selected slot means bare fists; unreported weapons are hidden.
			menu:SetInventory({}, 1)
			expect(menu.SelectedWeapon).to.equal("Fists")
			expect(fists_button.Visible).to.equal(true)
			expect(katana_button.Visible).to.equal(false)
			expect(fists_selection.Visible).to.equal(true)

			menu:Destroy()
			gui:Destroy()
		end)

		it("defers character setup until the character is parented to Workspace", function()
			local player_controller_module = find_controller("PlayerController")
			expect(player_controller_module ~= nil).to.equal(true)
			if not player_controller_module then
				return
			end

			local created = {}
			local controller = make_player_controller(require(player_controller_module), created)
			local character = Instance.new("Model")

			controller:_set_character(character)
			expect(#created).to.equal(0)
			expect(controller.PendingCharacter).to.equal(character)

			character.Parent = Workspace
			-- AncestryChanged may be deferred; one frame is enough for it to run.
			task.wait()
			expect(#created).to.equal(1)
			expect(created[1]).to.equal(character)
			expect(controller.PendingCharacter).to.equal(nil)
			expect(controller.PendingTrove).to.equal(nil)

			controller.Trove:Destroy()
			character:Destroy()
		end)

		it("drops a pending character that is replaced before reaching Workspace", function()
			local player_controller_module = find_controller("PlayerController")
			expect(player_controller_module ~= nil).to.equal(true)
			if not player_controller_module then
				return
			end

			local created = {}
			local controller = make_player_controller(require(player_controller_module), created)
			local old_character = Instance.new("Model")
			local new_character = Instance.new("Model")

			controller:_set_character(old_character)
			controller:_set_character(new_character)
			expect(controller.PendingCharacter).to.equal(new_character)

			old_character.Parent = Workspace
			task.wait()
			expect(#created).to.equal(0)

			controller.Trove:Destroy()
			old_character:Destroy()
			new_character:Destroy()
		end)
	end)
end
