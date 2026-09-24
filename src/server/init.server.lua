local PlayerService = require(script.services.PlayerService)
local WeaponService = require(script.services.WeaponService)

local player_service = PlayerService.new()
local weapon_service = WeaponService.new(player_service)

-- Keep service references owned by the server entrypoint.
-- Additional services can be added here explicitly as the game grows.
return {
	PlayerService = player_service,
	WeaponService = weapon_service,
}
