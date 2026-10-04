--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Config = require(ReplicatedStorage.shared.config)
local Signal = require(ReplicatedStorage.packages.Signal)
local UiContracts = require(StarterPlayer.StarterPlayerScripts.client.UiContracts)

-- Specs must never yield indefinitely, so every lookup uses FindFirstChild.
-- ServerStorage and ServerScriptService are empty when viewed from a client.
local IS_SERVER = RunService:IsServer()

-- Modules are looked up with FindFirstChild (never yielding), so the analyzer
-- cannot resolve them; the exports are checked at runtime instead.
local function require_found(module: Instance): any
	return (require :: any)(module)
end

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

-- Session LoadoutClient stand-in with the fields and signals UI modules read.
local function make_loadout()
	return {
		EquippedId = Catalog.DefaultId,
		Entries = {},
		SelectedSlot = 0,
		EquippedChanged = Signal.new(),
		InventoryChanged = Signal.new(),
		Selected = {},
		SelectWeapon = function(self, weapon_id)
			table.insert(self.Selected, weapon_id)
			return true
		end,
		SelectUid = function(self, uid)
			table.insert(self.Selected, uid)
		end,
		SelectSlot = function(self, slot)
			table.insert(self.Selected, slot)
		end,
	}
end

-- PlayerController over a fake player, with character construction recorded
-- instead of building real controllers, so only the Workspace wait runs.
local function make_player_controller(PlayerController, created)
	local player = {
		Parent = Players,
		Character = nil,
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
	}
	local input = { ActionBegan = Signal.new(), ActionEnded = Signal.new() }
	local loadout = make_loadout()
	local controller = PlayerController.new({
		player = player,
		input = input,
		combat = {},
		loadout = loadout,
		scheduler = {},
		create_character = function(deps)
			table.insert(created, deps.character)
			return { Character = deps.character, Destroy = function() end }
		end,
	})
	return controller, player, input, loadout
end

-- Stands in for UIController so UI modules can be built without PlayerGui.
local function make_ui_controller(templates)
	return {
		Combat = { HitConfirmed = Signal.new() },
		Loadout = make_loadout(),
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
			local fx_remote = remotes and remotes:FindFirstChild("CombatFx")
			expect(fx_remote ~= nil and fx_remote:IsA("UnreliableRemoteEvent")).to.equal(true)

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

		-- The same checks the server runs at boot (compose/Content), one weapon at a time.
		for _, weapon_id in ipairs(Catalog.Ids()) do
			local current_weapon_id = weapon_id
			it("matches the " .. current_weapon_id .. " model template to its definition", function()
				if not IS_SERVER then
					return
				end
				local AssetContracts = require(ServerScriptService.server.AssetContracts)
				local single = {
					Ids = function()
						return { current_weapon_id }
					end,
					Get = Catalog.Get,
				}
				local errors = AssetContracts.Verify(single, ServerStorage:FindFirstChild(Config.World.Folders.WeaponModels))
				if #errors > 0 then
					error(table.concat(errors, "\n"), 0)
				end
			end)
		end

		it("matches the UI templates to the catalog", function()
			local errors = UiContracts.Verify(Catalog, ReplicatedStorage:FindFirstChild(Config.World.Folders.UiTemplates))
			if #errors > 0 then
				error(table.concat(errors, "\n"), 0)
			end
		end)

		it("loads client controller and session modules and exposes constructors", function()
			local player_scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
			local client = player_scripts and player_scripts:FindFirstChild("client")
			local controllers = client and client:FindFirstChild("controllers")
			local session = client and client:FindFirstChild("session")
			expect(controllers ~= nil).to.equal(true)
			expect(session ~= nil).to.equal(true)
			if not controllers or not session then
				return
			end

			local modules: { { Name: string, Module: Instance? } } = {}
			for _, name in ipairs({
				"AnimationController",
				"CharacterController",
				"CharacterState",
				"CombatController",
				"InputController",
				"MovementController",
				"ParkourController",
				"PlayerController",
				"UIController",
				"WeaponController",
			}) do
				table.insert(modules, { Name = name, Module = controllers:FindFirstChild(name) })
			end
			for _, name in ipairs({ "CombatClient", "LoadoutClient" }) do
				table.insert(modules, { Name = name, Module = session:FindFirstChild(name) })
			end

			for _, entry in ipairs(modules) do
				local module = entry.Module
				expect(module ~= nil and module:IsA("ModuleScript")).to.equal(true)
				if module then
					local exported = require_found(module)
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
				{ "InventoryService", "SelectUid" },
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
					local exported = require_found(module)
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

			local menu = require_found(weapon_menu_module).new(ui_controller)
			expect(menu.Gui).to.equal(nil)
			ui_controller.Loadout.InventoryChanged:Fire({ { Slot = 2, Uid = "uid-katana", ItemId = "Katana" } }, 2)
			ui_controller.Loadout.EquippedChanged:Fire("Katana")
			expect(menu.SelectedWeapon).to.equal(nil)
			menu:Destroy()

			local hitmarker = require_found(hitmarker_module).new(ui_controller)
			expect(hitmarker.Gui).to.equal(nil)
			ui_controller.Combat.HitConfirmed:Fire(1, nil)
			hitmarker:Show()
			hitmarker:Destroy()
		end)

		it("shows the hitmarker on a confirmed hit", function()
			local hitmarker_module = find_ui_module("Hitmarker")
			expect(hitmarker_module ~= nil).to.equal(true)
			if not hitmarker_module then
				return
			end

			local gui = Instance.new("ScreenGui")
			local visual = Instance.new("Frame")
			visual.Name = "Hitmarker"
			visual.Parent = gui

			local ui_controller = make_ui_controller({ Hitmarker = gui })
			local hitmarker = require_found(hitmarker_module).new(ui_controller)
			expect(visual.Visible).to.equal(false)

			ui_controller.Combat.HitConfirmed:Fire(1, nil)
			expect(visual.Visible).to.equal(true)

			hitmarker:Destroy()
			-- After Destroy the subscription is gone and firing is harmless.
			ui_controller.Combat.HitConfirmed:Fire(1, nil)
		end)

		it("syncs WeaponMenu slots and selection from the loadout", function()
			local weapon_menu_module = find_ui_module("WeaponMenu")
			expect(weapon_menu_module ~= nil).to.equal(true)
			if not weapon_menu_module then
				return
			end

			local gui = Instance.new("ScreenGui")
			local fists_button, fists_selection = make_weapon_button(gui, Catalog.DefaultId)
			local katana_button, katana_selection = make_weapon_button(gui, "Katana")

			local ui_controller = make_ui_controller({ WeaponMenu = gui })
			local loadout = ui_controller.Loadout
			local menu = require_found(weapon_menu_module).new(ui_controller)
			expect(menu.SelectedWeapon).to.equal(Catalog.DefaultId)
			expect(fists_selection.Visible).to.equal(true)

			loadout.InventoryChanged:Fire({ { Slot = 2, Uid = "uid-katana", ItemId = "Katana" } }, 2)
			expect(menu.SelectedWeapon).to.equal("Katana")
			expect(katana_button.Visible).to.equal(true)
			expect(katana_selection.Visible).to.equal(true)
			expect(fists_selection.Visible).to.equal(false)

			-- No selected slot means the default weapon; unreported weapons are hidden.
			loadout.InventoryChanged:Fire({}, 0)
			expect(menu.SelectedWeapon).to.equal(Catalog.DefaultId)
			expect(fists_button.Visible).to.equal(true)
			expect(katana_button.Visible).to.equal(false)
			expect(fists_selection.Visible).to.equal(true)

			loadout.EquippedChanged:Fire("Katana")
			expect(menu.SelectedWeapon).to.equal("Katana")

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
			local controller, player = make_player_controller(require_found(player_controller_module), created)
			local character = Instance.new("Model")

			player.CharacterAdded:Fire(character)
			expect(#created).to.equal(0)
			expect(controller.PendingCharacter).to.equal(character)

			character.Parent = Workspace
			-- AncestryChanged may be deferred; one frame is enough for it to run.
			task.wait()
			expect(#created).to.equal(1)
			expect(created[1]).to.equal(character)
			expect(controller.PendingCharacter).to.equal(nil)
			expect(controller.PendingTrove).to.equal(nil)

			controller:Destroy()
			character:Destroy()
		end)

		it("drops a pending character that is replaced before reaching Workspace", function()
			local player_controller_module = find_controller("PlayerController")
			expect(player_controller_module ~= nil).to.equal(true)
			if not player_controller_module then
				return
			end

			local created = {}
			local controller, player = make_player_controller(require_found(player_controller_module), created)
			local old_character = Instance.new("Model")
			local new_character = Instance.new("Model")

			player.CharacterAdded:Fire(old_character)
			player.CharacterAdded:Fire(new_character)
			expect(controller.PendingCharacter).to.equal(new_character)

			old_character.Parent = Workspace
			task.wait()
			expect(#created).to.equal(0)

			controller:Destroy()
			old_character:Destroy()
			new_character:Destroy()
		end)

		it("maps slot hotkeys to loadout slot requests", function()
			local player_controller_module = find_controller("PlayerController")
			expect(player_controller_module ~= nil).to.equal(true)
			if not player_controller_module then
				return
			end

			local controller, _, input, loadout = make_player_controller(require_found(player_controller_module), {})
			input.ActionBegan:Fire("Slot3")
			input.ActionBegan:Fire("Slot9")
			input.ActionBegan:Fire("Primary")

			expect(#loadout.Selected).to.equal(2)
			expect(loadout.Selected[1]).to.equal(3)
			expect(loadout.Selected[2]).to.equal(9)
			controller:Destroy()
		end)
	end)
end
