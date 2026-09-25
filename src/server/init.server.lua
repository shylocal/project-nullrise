local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerService = require(script.services.PlayerService)
local InventoryService = require(script.services.InventoryService)
local WeaponService = require(script.services.WeaponService)
local CombatService = require(script.services.CombatService)

local CombatRemote = ReplicatedStorage.remotes.Combat

local player_service = PlayerService.new()
local inventory_service = InventoryService.new(player_service)
local weapon_service = WeaponService.new(player_service, inventory_service)
local combat_service = CombatService.new(player_service, weapon_service, CombatRemote)

return {
	PlayerService = player_service,
	InventoryService = inventory_service,
	WeaponService = weapon_service,
	CombatService = combat_service,
}
