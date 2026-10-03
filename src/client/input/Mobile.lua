local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.shared.input.Actions)

local MobileInput = {}
MobileInput.__index = MobileInput

local Bindings = {
	[Actions.Primary] = "Nullrise_Primary",
	[Actions.Sprint] = "Nullrise_Sprint",
	[Actions.Jump] = "Nullrise_Jump",
	[Actions.Forward] = "Nullrise_Forward",
	[Actions.Backward] = "Nullrise_Backward",
	[Actions.Left] = "Nullrise_Left",
	[Actions.Right] = "Nullrise_Right",
	[Actions.Slot1] = "Nullrise_Slot1",
	[Actions.Slot2] = "Nullrise_Slot2",
}

local Titles = {
	[Actions.Primary] = "Attack",
	[Actions.Sprint] = "Sprint",
	[Actions.Jump] = "Jump",
	[Actions.Forward] = "Forward",
	[Actions.Backward] = "Back",
	[Actions.Left] = "Left",
	[Actions.Right] = "Right",
	[Actions.Slot1] = "Slot 1",
	[Actions.Slot2] = "Slot 2",
}

function MobileInput.new(on_began, on_ended)
	local self = setmetatable({
		Actions = {},
	}, MobileInput)

	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function MobileInput:_start(on_began, on_ended)
	for action, binding_name in pairs(Bindings) do
		self.Actions[action] = binding_name

		ContextActionService:BindAction(
			binding_name,
			function(_, input_state)
				if input_state == Enum.UserInputState.Begin then
					on_began(action, "Mobile", action)
				elseif input_state == Enum.UserInputState.End
					or input_state == Enum.UserInputState.Cancel then
					on_ended(action, "Mobile", action)
				end

				return Enum.ContextActionResult.Sink
			end,
			true
		)

		ContextActionService:SetTitle(binding_name, Titles[action])
	end
end

function MobileInput:Destroy()
	for _, binding_name in pairs(self.Actions) do
		ContextActionService:UnbindAction(binding_name)
	end

	table.clear(self.Actions)
end

return MobileInput
