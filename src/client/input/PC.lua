local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift
end


local Bindings = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,
	[Enum.KeyCode.Space] = Actions.Jump,
	[Enum.KeyCode.W] = Actions.Forward,
	[Enum.KeyCode.S] = Actions.Backward,
	[Enum.KeyCode.A] = Actions.Left,
	[Enum.KeyCode.D] = Actions.Right,
	[Enum.KeyCode.One] = Actions.Slot1,
	[Enum.KeyCode.Two] = Actions.Slot2,
}

function PCInput.new(on_began, on_ended)
	local self = setmetatable({ Trove = Trove.new(), SprintKeyDown = false, SprintActive = false }, PCInput)
	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- Left Shift is the sole sprint key; avoid overlapping Shift aliases.
function PCInput:_set_sprint_active(enabled)
	if self.SprintActive == enabled then
		return
	end
	self.SprintActive = enabled
	if enabled then
		self.OnBegan(Actions.Sprint, "PC", "SprintToggle")
	else
		self.OnEnded(Actions.Sprint, "PC", "SprintToggle")
	end
end

function PCInput:_on_sprint_input(action_name, input_state, input)
	local key_code = input.KeyCode
		end
	end

	return Enum.ContextActionResult.Pass
end

function PCInput:_bind_sprint_actions()
	local sprint_action_name = "ProjectNullriseSprint_LeftShift"
	ContextActionService:UnbindAction(sprint_action_name)
	ContextActionService:BindAction(sprint_action_name, function(action_name, input_state, input)
		return self:_on_sprint_input(action_name, input_state, input)
	end, false, Enum.KeyCode.LeftShift)
	self.Trove:Add(function()
		ContextActionService:UnbindAction(sprint_action_name)
	end)
end

function PCInput:_start(on_began, on_ended)
	self.Destroyed = false
	self.OnBegan = on_began
	self.OnEnded = on_ended
	self:_bind_sprint_actions()
	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		if is_sprint_key(input.KeyCode) then return end
		if game_processed then
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action then
			on_began(action, "PC", source_id)
		end
	end)
	self.Trove:Connect(UserInputService.InputEnded, function(input)
		if is_sprint_key(input.KeyCode) then return end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:Destroy()
	self.Destroyed = true
	self.OnBegan = nil
	self.OnEnded = nil
	self.SprintKeyDown = false
	self.SprintActive = false
	self.Trove:Destroy()
end

return PCInput
