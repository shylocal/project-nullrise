local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.shared.input.Actions)

local GamepadInput = {}
GamepadInput.__index = GamepadInput

local Bindings = {
	[Actions.Primary] = { "Nullrise_GamepadPrimary", Enum.KeyCode.ButtonR2 },
	[Actions.Sprint] = { "Nullrise_GamepadSprint", Enum.KeyCode.ButtonL3 },
	[Actions.Jump] = { "Nullrise_GamepadJump", Enum.KeyCode.ButtonA },
	[Actions.Forward] = { "Nullrise_GamepadForward", Enum.KeyCode.DPadUp },
	[Actions.Backward] = { "Nullrise_GamepadBackward", Enum.KeyCode.DPadDown },
	[Actions.Left] = { "Nullrise_GamepadLeft", Enum.KeyCode.DPadLeft },
	[Actions.Right] = { "Nullrise_GamepadRight", Enum.KeyCode.DPadRight },
	[Actions.Slot1] = { "Nullrise_GamepadSlot1", Enum.KeyCode.ButtonX },
	[Actions.Slot2] = { "Nullrise_GamepadSlot2", Enum.KeyCode.ButtonY },
}

function GamepadInput.new(on_began, on_ended)
	local self = setmetatable({
		Actions = {},
	}, GamepadInput)

	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function GamepadInput:_start(on_began, on_ended)
	for action, binding in pairs(Bindings) do
		local binding_name = binding[1]
		local key_code = binding[2]
		self.Actions[action] = binding_name

		ContextActionService:BindAction(
			binding_name,
			function(_, input_state, input_object)
				if not input_object or input_object.UserInputType.Name:sub(1, 7) ~= "Gamepad" then
					return Enum.ContextActionResult.Pass
				end

				local source_id = input_object.KeyCode
				if input_state == Enum.UserInputState.Begin then
					on_began(action, "Gamepad", source_id)
				elseif input_state == Enum.UserInputState.End
					or input_state == Enum.UserInputState.Cancel then
					on_ended(action, "Gamepad", source_id)
				end

				return Enum.ContextActionResult.Sink
			end,
			false,
			key_code
		)
	end
end

function GamepadInput:Destroy()
	for _, binding_name in pairs(self.Actions) do
		ContextActionService:UnbindAction(binding_name)
	end

	table.clear(self.Actions)
end

return GamepadInput
