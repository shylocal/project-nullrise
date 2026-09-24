local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerService = require(script.services.PlayerService)
local WeaponService = require(script.services.WeaponService)
local CombatService = require(script.services.CombatService)

local remotes = ReplicatedStorage.remotes
local combat_remote = remotes.Combat

local player_service = PlayerService.new()
local weapon_service = WeaponService.new(player_service)
local combat_service = CombatService.new(player_service, weapon_service, combat_remote)

return {
	PlayerService = player_service,
	WeaponService = weapon_service,
	CombatService = combat_service,
}
