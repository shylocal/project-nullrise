-- Client composition root. Services are built in order and torn down in
-- reverse by the Runtime; session clients outlive every character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local InputController = require(script.controllers.InputController)
local UIController = require(script.controllers.UIController)
local PlayerController = require(script.controllers.PlayerController)
local CharacterController = require(script.controllers.CharacterController)
local TrackCache = require(script.controllers.AnimationController.TrackCache)
local CombatClient = require(script.session.CombatClient)
local LoadoutClient = require(script.session.LoadoutClient)
local UiContracts = require(script.UiContracts)

local player = Players.LocalPlayer
local remotes = ReplicatedStorage.remotes

-- UI templates are checked against the Catalog before anything is built.
UiContracts.Report(
	UiContracts.Verify(Catalog, ReplicatedStorage:FindFirstChild(Config.World.Folders.UiTemplates)),
	RunService:IsStudio()
)

local NULL_SERVICE = { Destroy = function() end }

local rt = Runtime.new("Client")

rt:Add("Input", function()
	return InputController.new()
end)

rt:Add("Combat", function()
	return CombatClient.new({ remote = remotes.Combat, fx_remote = remotes.CombatFx })
end)

rt:Add("Loadout", function()
	return LoadoutClient.new({ inventory_remote = remotes.Inventory, weapon_remote = remotes.Weapon })
end)

rt:Add("Preload", function()
	return TrackCache.preload(TrackCache.collect_catalog())
end)

-- UI is optional: a failure there is reported but gameplay still starts.
rt:Add("UI", function(get)
	local ok, ui = pcall(UIController.new, {
		combat = get("Combat"),
		loadout = get("Loadout"),
		player_gui = player:WaitForChild("PlayerGui"),
	})
	if ok then
		return ui
	end
	warn(("UIController failed to start; continuing without UI: %s"):format(tostring(ui)))
	return NULL_SERVICE
end)

rt:Add("Player", function(get)
	return PlayerController.new({
		player = player,
		input = get("Input"),
		combat = get("Combat"),
		loadout = get("Loadout"),
		scheduler = Scheduler.real(),
		create_character = CharacterController.new,
	})
end)

rt:Start()

script.Destroying:Connect(function()
	rt:Destroy()
end)
