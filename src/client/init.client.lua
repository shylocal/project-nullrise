local InputController = require(script.controllers.InputController)
local WeaponMenuController = require(script.controllers.WeaponMenuController)
local PlayerController = require(script.controllers.PlayerController)

local player = game:GetService("Players").LocalPlayer

local input_controller = InputController.new()
local weapon_menu_controller = WeaponMenuController.new()
local player_controller = PlayerController.new(
	player,
	input_controller,
	weapon_menu_controller
)

return {
	InputController = input_controller,
	WeaponMenuController = weapon_menu_controller,
	PlayerController = player_controller,
}
