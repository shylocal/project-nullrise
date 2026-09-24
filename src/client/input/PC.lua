local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local Bindings = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,

	[Enum.KeyCode.LeftShift] = Actions.Sprint,
	[Enum.KeyCode.RightShift] = Actions.Sprint,
}

function PCInput.new(on_began, on_ended)
	local self = setmetatable({
		Connections = {},
	}, PCInput)

	self:_start(on_began, on_ended)

	return self
end

function PCInput:_start(on_began, on_ended)
	self.Connections.InputBegan = UserInputService.InputBegan:Connect(function(input, game_processed)
		if game_processed then
			return
		end

		local action = self:_get_action(input)
		if action then
			on_began(action)
		end
	end)

	self.Connections.InputEnded = UserInputService.InputEnded:Connect(function(input)
		local action = self:_get_action(input)
		if action then
			on_ended(action)
		end
	end)
end

function PCInput:_get_action(input)
	return Bindings[input.UserInputType] or Bindings[input.KeyCode]
end

function PCInput:Destroy()
	for _, connection in pairs(self.Connections) do
		connection:Disconnect()
	end

	table.clear(self.Connections)
end

return PCInput
