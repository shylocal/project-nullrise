local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_KEYS = {
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift,
}

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

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
	local self = setmetatable({ Trove = Trove.new(), SprintKeysDown = {} }, PCInput)
	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- Release only the Shift key whose matching press edge was observed. An
-- unmatched alias release must not clear a different key that is still held.
function PCInput:_release_sprint_key(released_key, on_ended)
	local held = self.SprintKeysDown
	local key_to_release = held[released_key] and released_key or nil
	warn(("[InputDebug][PC] tracked release key=%s matched=%s"):format(tostring(released_key), tostring(key_to_release)))
	if key_to_release then
		held[key_to_release] = nil
		on_ended(Actions.Sprint, "PC", key_to_release)
	end
end

function PCInput:_start(on_began, on_ended)
	self.Destroyed = false
	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		warn(("[InputDebug][PC] raw InputBegan key=%s type=%s processed=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(game_processed)))
		if game_processed then
			warn(("[InputDebug][PC] processed begin ignored key=%s"):format(tostring(input.KeyCode)))
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action then
			if action == Actions.Sprint and is_sprint_key(input.KeyCode) then self.SprintKeysDown[input.KeyCode] = true end
			warn(("[InputDebug][PC] InputBegan key=%s type=%s action=%s sourceId=%s processed=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(action), tostring(source_id), tostring(game_processed)))
			on_began(action, "PC", source_id)
		end
	end)
	self.Trove:Connect(UserInputService.InputEnded, function(input)
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action == Actions.Sprint or is_sprint_key(input.KeyCode) then
			warn(("[InputDebug][PC] InputEnded key=%s type=%s action=%s sourceId=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(action), tostring(source_id)))
			self:_release_sprint_key(input.KeyCode, on_ended)
		elseif action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:Destroy()
	self.Destroyed = true
	table.clear(self.SprintKeysDown)
	self.Trove:Destroy()
end

return PCInput
