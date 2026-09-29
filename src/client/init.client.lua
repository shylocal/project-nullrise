local InputController = require(script.controllers.InputController)
local UIController = require(script.controllers.UIController)
local PlayerController = require(script.controllers.PlayerController)

local player = game:GetService("Players").LocalPlayer

local input_controller
local ui_controller
local player_controller

local ok, err = pcall(function()
	input_controller = InputController.new()
	ui_controller = UIController.new()
	player_controller = PlayerController.new(
		player,
		input_controller,
		ui_controller
	)
end)

if not ok then
	if player_controller then player_controller:Destroy() end
	if ui_controller then ui_controller:Destroy() end
	if input_controller then input_controller:Destroy() end
	error(err, 0)
end

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

script.Destroying:Connect(function()
	runtime:Destroy()
end)

return runtime
