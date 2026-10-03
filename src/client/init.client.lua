local InputController = require(script.controllers.InputController)
local UIController = require(script.controllers.UIController)
local PlayerController = require(script.controllers.PlayerController)

local player = game:GetService("Players").LocalPlayer

local input_controller
local ui_controller
local player_controller

-- UI is optional: a failure there is reported but gameplay still starts.
local ui_ok, ui_err = pcall(function()
	ui_controller = UIController.new()
end)
if not ui_ok then
	ui_controller = nil
	warn(("UIController failed to start; continuing without UI: %s"):format(tostring(ui_err)))
end

local ok, err = pcall(function()
	input_controller = InputController.new()
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
	if self.UIController then
		self.UIController:Destroy()
	end
	self.InputController:Destroy()
end

script.Destroying:Connect(function()
	runtime:Destroy()
end)
