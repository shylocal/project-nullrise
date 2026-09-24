local InputController = require(script.controllers.InputController)
local PlayerController = require(script.controllers.PlayerController)

local player = game:GetService("Players").LocalPlayer

local input_controller = InputController.new()
local player_controller = PlayerController.new(player)

return {
	InputController = input_controller,
	PlayerController = player_controller,
}
