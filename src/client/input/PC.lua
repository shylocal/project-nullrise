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

-- Temporary diagnostic logging for the reported stuck-Sprint input sequence.
local function get_shift_trace(held_keys)
	return string.format(
		"tracked[L=%s,R=%s] physical[L=%s,R=%s]",
		tostring(held_keys[Enum.KeyCode.LeftShift] == true),
		tostring(held_keys[Enum.KeyCode.RightShift] == true),
		tostring(UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)),
		tostring(UserInputService:IsKeyDown(Enum.KeyCode.RightShift))
	)
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
	local self = setmetatable({
		Trove = Trove.new(),
		HeldSprintKeys = {},
	}, PCInput)

	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function PCInput._begin_sprint_key(held_keys, key_code, on_began)
	if not is_sprint_key(key_code) then
		return false
	end

	held_keys[key_code] = true
	on_began(Actions.Sprint, "PC", key_code)
	return true
end

-- Roblox can suppress one side of a simultaneous Shift press/release pair.
-- A release for a Shift key we never observed means the other tracked Shift
-- may be stale too, so clear the entire aliased action in that case.
function PCInput._end_sprint_key(held_keys, key_code, on_ended, is_key_down)
	if not is_sprint_key(key_code) then
		return false
	end

	local was_tracked = held_keys[key_code] == true
	held_keys[key_code] = nil

	if not was_tracked then
		for _, sprint_key in ipairs(SPRINT_KEYS) do
			held_keys[sprint_key] = nil
			on_ended(Actions.Sprint, "PC", sprint_key)
		end
		return true
	end

	on_ended(Actions.Sprint, "PC", key_code)

	for _, sprint_key in ipairs(SPRINT_KEYS) do
		if held_keys[sprint_key] and not is_key_down(sprint_key) then
			held_keys[sprint_key] = nil
			on_ended(Actions.Sprint, "PC", sprint_key)
		end
	end

	return true
end

function PCInput:_start(on_began, on_ended)
	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		table.clear(self.HeldSprintKeys)
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC] InputBegan key=%s type=%s processed=%s before{%s}",
				tostring(input.KeyCode),
				tostring(input.UserInputType),
				tostring(game_processed),
				get_shift_trace(self.HeldSprintKeys)
			))
		end

		if game_processed then
			if is_shift then
				print("[ShiftTrace][PC] InputBegan ignored because gameProcessedEvent=true")
			end
			return
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if not action then
			return
		end

		if action == Actions.Sprint then
			local handled = PCInput._begin_sprint_key(self.HeldSprintKeys, input.KeyCode, on_began)
			print(string.format(
				"[ShiftTrace][PC] Sprint begin handled=%s action=%s sourceId=%s after{%s}",
				tostring(handled),
				tostring(action),
				tostring(source_id),
				get_shift_trace(self.HeldSprintKeys)
			))
		else
			on_began(action, "PC", source_id)
		end
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC] InputEnded key=%s type=%s before{%s}",
				tostring(input.KeyCode),
				tostring(input.UserInputType),
				get_shift_trace(self.HeldSprintKeys)
			))
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType

		if is_shift then
			local handled = PCInput._end_sprint_key(self.HeldSprintKeys, input.KeyCode, on_ended, function(key_code)
				return UserInputService:IsKeyDown(key_code)
			end)
			print(string.format(
				"[ShiftTrace][PC] Sprint end handled=%s action=%s sourceId=%s after{%s}",
				tostring(handled),
				tostring(action),
				tostring(source_id),
				get_shift_trace(self.HeldSprintKeys)
			))
		elseif action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:ResetHeldKeys()
	table.clear(self.HeldSprintKeys)
end

function PCInput:Destroy()
	self:ResetHeldKeys()
	self.Trove:Destroy()
end

return PCInput
