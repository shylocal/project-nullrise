--!strict
-- Item services: the inventory (selection) and the weapon it equips.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)

local server = script.Parent.Parent
local Core = require(server.compose.Core)
local InventoryService = require(server.services.InventoryService)
local WeaponService = require(server.services.WeaponService)

return function(rt: Runtime.Runtime, env: Core.ServerEnv): ()
	rt:Add("InventoryService", function(get)
		return InventoryService.new({
			players = get("PlayerService"),
			remote = env.Remotes:FindFirstChild("Inventory"),
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)

	rt:Add("WeaponService", function(get)
		return WeaponService.new({
			players = get("PlayerService"),
			inventory = get("InventoryService"),
			remote = env.Remotes:FindFirstChild("Weapon"),
			weapon_models = env.WeaponModels,
		})
	end)
end
