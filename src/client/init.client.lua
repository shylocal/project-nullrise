local InputController = require(script.controllers.InputController)
local UIController = require(script.controllers.UIController)
local PlayerController = require(script.controllers.PlayerController)

local player = game:GetService("Players").LocalPlayer

local input_controller = InputController.new()
local ui_controller = UIController.new()
local player_controller = PlayerController.new(
	player,
	input_controller,
	ui_controller
)

return {
	InputController = input_controller,
	UIController = ui_controller,
	PlayerController = player_controller,
}
