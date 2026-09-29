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

local runtime = {
	InputController = input_controller,
	UIController = ui_controller,
	PlayerController = player_controller,
	_destroyed = false,
}

-- Tear down dependents before the shared services they reference.
function runtime:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self.PlayerController:Destroy()
	self.UIController:Destroy()
	self.InputController:Destroy()
end

return runtime
