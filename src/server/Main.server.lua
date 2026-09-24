--!strict

local WeaponService = require(script.services.WeaponService)

local Server = {
	WeaponService = WeaponService.new(),
}

function Server.start()
	-- Server bootstrap lives here.
	-- Game-specific services can be added explicitly as the project grows.
end

Server.start()
