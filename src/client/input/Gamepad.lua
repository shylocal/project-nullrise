local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.shared.input.Actions)

local GamepadInput = {}
GamepadInput.__index = GamepadInput

-- Sink: whether a consumed input is hidden from lower-priority bindings.
-- Jump and the D-pad only observe input so Roblox's default jump and gamepad
-- UI navigation keep working. UINavigation inputs are not reported at all
-- while a GuiObject is selected, since they then belong to the UI.
local Bindings = {
	[Actions.Primary] = { Name = "Nullrise_GamepadPrimary", KeyCode = Enum.KeyCode.ButtonR2, Sink = true },
	[Actions.Sprint] = { Name = "Nullrise_GamepadSprint", KeyCode = Enum.KeyCode.ButtonL3, Sink = true },
	[Actions.Jump] = { Name = "Nullrise_GamepadJump", KeyCode = Enum.KeyCode.ButtonA, Sink = false, UINavigation = true },
	[Actions.Forward] = { Name = "Nullrise_GamepadForward", KeyCode = Enum.KeyCode.DPadUp, Sink = false, UINavigation = true },
	[Actions.Backward] = { Name = "Nullrise_GamepadBackward", KeyCode = Enum.KeyCode.DPadDown, Sink = false, UINavigation = true },
	[Actions.Left] = { Name = "Nullrise_GamepadLeft", KeyCode = Enum.KeyCode.DPadLeft, Sink = false, UINavigation = true },
	[Actions.Right] = { Name = "Nullrise_GamepadRight", KeyCode = Enum.KeyCode.DPadRight, Sink = false, UINavigation = true },
	[Actions.Slot1] = { Name = "Nullrise_GamepadSlot1", KeyCode = Enum.KeyCode.ButtonX, Sink = true },
	[Actions.Slot2] = { Name = "Nullrise_GamepadSlot2", KeyCode = Enum.KeyCode.ButtonY, Sink = true },
}

GamepadInput.Bindings = Bindings

function GamepadInput.new(on_began, on_ended)
	assert(type(on_began) == "function", "GamepadInput requires on_began")
	assert(type(on_ended) == "function", "GamepadInput requires on_ended")

	local self = setmetatable({
		Actions = {},
		OnBegan = on_began,
		OnEnded = on_ended,
	}, GamepadInput)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function GamepadInput:_start()
	for action, binding in pairs(Bindings) do
		self.Actions[action] = binding.Name

		ContextActionService:BindAction(
			binding.Name,
			function(_, input_state, input_object)
				return self:_on_input(action, binding, input_state, input_object)
			end,
			false,
			binding.KeyCode
		)
	end
end

function GamepadInput:_is_ui_navigating()
	return GuiService.SelectedObject ~= nil
end

function GamepadInput:_on_input(action, binding, input_state, input_object)
	if not input_object or input_object.UserInputType.Name:sub(1, 7) ~= "Gamepad" then
		return Enum.ContextActionResult.Pass
	end

	local source_id = input_object.KeyCode
	if input_state == Enum.UserInputState.Begin then
		if binding.UINavigation and self:_is_ui_navigating() then
			return Enum.ContextActionResult.Pass
		end
		if self.OnBegan then
			self.OnBegan(action, "Gamepad", source_id)
		end
	elseif input_state == Enum.UserInputState.End
		or input_state == Enum.UserInputState.Cancel then
		-- Always report releases; InputController ignores sources it never saw begin.
		if self.OnEnded then
			self.OnEnded(action, "Gamepad", source_id)
		end
	end

	if binding.Sink then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

function GamepadInput:Destroy()
	for _, binding_name in pairs(self.Actions) do
		ContextActionService:UnbindAction(binding_name)
	end

	table.clear(self.Actions)
	self.OnBegan = nil
	self.OnEnded = nil
end

return GamepadInput
