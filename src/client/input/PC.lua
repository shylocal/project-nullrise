local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
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
	local self = setmetatable({ Trove = Trove.new(), SprintKeysDown = {} }, PCInput)
	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- ContextActionService owns both Shift aliases as one sprint action. Keep
-- concrete key sources so releasing one alias cannot end the other.
function PCInput:_on_sprint_input(action_name, input_state, input)
	local key_code = input.KeyCode
	if not is_sprint_key(key_code) then
		return Enum.ContextActionResult.Pass
	end

	if input_state == Enum.UserInputState.Begin then
		self.SprintKeysDown[key_code] = true
		warn(("[InputDebug][PC] CAS sprint begin key=%s"):format(tostring(key_code)))
		self.OnBegan(Actions.Sprint, "PC", key_code)
	elseif input_state == Enum.UserInputState.End or input_state == Enum.UserInputState.Cancel then
		if self.SprintKeysDown[key_code] then
			self.SprintKeysDown[key_code] = nil
			warn(("[InputDebug][PC] CAS sprint end key=%s state=%s"):format(tostring(key_code), tostring(input_state)))
			self.OnEnded(Actions.Sprint, "PC", key_code)
		else
			warn(("[InputDebug][PC] CAS unmatched sprint end key=%s state=%s"):format(tostring(key_code), tostring(input_state)))
		end
	end

	return Enum.ContextActionResult.Pass
end

function PCInput:_start(on_began, on_ended)
	self.Destroyed = false
	self.OnBegan = on_began
	self.OnEnded = on_ended
	-- Give each physical key its own CAS action. A single action bound to
	-- both aliases can report an End for one key without a matching Begin
	-- for the other, so aggregate the independent action states ourselves.
	for _, key_code in ipairs({ Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift }) do
		local sprint_action_name = "ProjectNullriseSprint_" .. key_code.Name
		ContextActionService:BindAction(sprint_action_name, function(action_name, input_state, input)
			return self:_on_sprint_input(action_name, input_state, input)
		end, false, key_code)
		self.Trove:Add(function()
			ContextActionService:UnbindAction(sprint_action_name)
		end)
	end
	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		if is_sprint_key(input.KeyCode) then return end
		warn(("[InputDebug][PC] raw InputBegan key=%s type=%s processed=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(game_processed)))
		if game_processed then
			warn(("[InputDebug][PC] processed begin ignored key=%s"):format(tostring(input.KeyCode)))
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action then
			warn(("[InputDebug][PC] InputBegan key=%s type=%s action=%s sourceId=%s processed=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(action), tostring(source_id), tostring(game_processed)))
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
	table.clear(self.SprintKeysDown)
	self.Trove:Destroy()
end

return PCInput
