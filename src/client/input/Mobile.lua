local ContextActionService = game:GetService("ContextActionService")

local MobileInput = {}
MobileInput.__index = MobileInput

local Bindings = {
	Primary = "Nullrise_Primary",
	Sprint = "Nullrise_Sprint",
}

local Titles = {
	Primary = "Attack",
	Sprint = "Sprint",
}

function MobileInput.new(on_began, on_ended)
	local self = setmetatable({
		Actions = {},
	}, MobileInput)

	self:_start(on_began, on_ended)

	return self
end

function MobileInput:_start(on_began, on_ended)
	for action, binding_name in pairs(Bindings) do
		self.Actions[action] = binding_name

		ContextActionService:BindAction(
			binding_name,
			function(_, input_state)
				if input_state == Enum.UserInputState.Begin then
					on_began(action)
				elseif input_state == Enum.UserInputState.End
					or input_state == Enum.UserInputState.Cancel then
					on_ended(action)
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
