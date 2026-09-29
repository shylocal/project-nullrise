local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local Bindings = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,
	[Enum.KeyCode.LeftShift] = Actions.Sprint,
	[Enum.KeyCode.RightShift] = Actions.Sprint,
	[Enum.KeyCode.Space] = Actions.Jump,
	[Enum.KeyCode.W] = Actions.Forward,
	[Enum.KeyCode.S] = Actions.Backward,
	[Enum.KeyCode.A] = Actions.Left,
	[Enum.KeyCode.D] = Actions.Right,
	[Enum.KeyCode.One] = Actions.Slot1,
	[Enum.KeyCode.Two] = Actions.Slot2,
}

function PCInput.new(on_began, on_ended)
	local self = setmetatable({ Trove = Trove.new() }, PCInput)
	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function PCInput:_start(on_began, on_ended)
	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		if game_processed then return end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then on_began(action) end
	end)
	self.Trove:Connect(UserInputService.InputEnded, function(input)
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then on_ended(action) end
	end)
end

function PCInput:Destroy()
	self.Trove:Destroy()
end

return PCInput
