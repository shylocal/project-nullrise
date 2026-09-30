local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_SOURCE_ID = "KeyboardSprint"
local SHIFT_TRACE_VERSION = "diag-v11"

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

local function get_pressed_shift_keys()
	local pressed = {}
	for _, input in ipairs(UserInputService:GetKeysPressed()) do
		if is_sprint_key(input.KeyCode) then
			pressed[input.KeyCode] = true
		end
	end
	return pressed
end

local function get_shift_trace(held_keys, pressed_keys)
	local pressed_names = {}
	for key_code in pairs(pressed_keys) do
		table.insert(pressed_names, tostring(key_code))
	end
	table.sort(pressed_names)

	return string.format(
		"tracked[L=%s,R=%s] GetKeysPressed={%s}",
		tostring(held_keys[Enum.KeyCode.LeftShift] == true),
		tostring(held_keys[Enum.KeyCode.RightShift] == true),
		table.concat(pressed_names, ",")
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

function PCInput._reconcile_sprint_state(held_keys, source_active, pressed_keys, on_began, on_ended)
	table.clear(held_keys)
	for key_code, is_down in pairs(pressed_keys) do
		if is_down and is_sprint_key(key_code) then
			held_keys[key_code] = true
		end
	end

	local remains_active = next(held_keys) ~= nil
	local began = remains_active and not source_active
	local ended = not remains_active and source_active

	if began then
		on_began(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	elseif ended then
		on_ended(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	end

	return remains_active, began, ended
end

function PCInput.new(on_began, on_ended)
	local self = setmetatable({
		Trove = Trove.new(),
		HeldSprintKeys = {},
		SprintSourceActive = false,
		SprintMonitor = nil,
		Destroyed = false,
	}, PCInput)

	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function PCInput:_stop_sprint_monitor(reason)
	if self.SprintMonitor then
		print(string.format(
			"[ShiftTrace][PC][%s] monitor stopping reason=%s active=%s",
			SHIFT_TRACE_VERSION,
			tostring(reason or "unspecified"),
			tostring(self.SprintSourceActive)
		))
		self.SprintMonitor:Disconnect()
		self.SprintMonitor = nil
	end
end

function PCInput:_reconcile_sprint(on_began, on_ended, reason, event_key, include_event_key)
	local pressed_keys = get_pressed_shift_keys()
	-- InputBegan can fire before GetKeysPressed reflects the new key. Include
	-- that began key as a fallback; InputEnded always trusts the current list.
	if include_event_key and is_sprint_key(event_key) then
		pressed_keys[event_key] = true
	end

	local before_active = self.SprintSourceActive
	local remains_active, began, ended = PCInput._reconcile_sprint_state(
		self.HeldSprintKeys,
		before_active,
		pressed_keys,
		on_began,
		on_ended
	)
	self.SprintSourceActive = remains_active

	print(string.format(
		"[ShiftTrace][PC][%s] reconcile reason=%s eventKey=%s activeBefore=%s began=%s ended=%s activeAfter=%s keys{%s}",
		SHIFT_TRACE_VERSION,
		tostring(reason),
		tostring(event_key),
		tostring(before_active),
		tostring(began),
		tostring(ended),
		tostring(remains_active),
		get_shift_trace(self.HeldSprintKeys, pressed_keys)
	))

	if remains_active then
		self:_start_sprint_monitor(on_began, on_ended)
	else
		self:_stop_sprint_monitor("NoShiftKeysDown:" .. tostring(reason))
	end
end

function PCInput:_start_sprint_monitor(on_began, on_ended)
	if self.SprintMonitor or self.Destroyed then
		return
	end

	local elapsed = 0
	print(string.format(
		"[ShiftTrace][PC][%s] monitor started",
		SHIFT_TRACE_VERSION
	))
	self.SprintMonitor = RunService.Heartbeat:Connect(function(delta_time)
		if self.Destroyed or not self.SprintSourceActive then
			return
		end

		elapsed += delta_time
		if elapsed >= 0.5 then
			elapsed = 0
			local pressed_keys = get_pressed_shift_keys()
			print(string.format(
				"[ShiftTrace][PC][%s] heartbeat active=%s keys{%s}",
				SHIFT_TRACE_VERSION,
				tostring(self.SprintSourceActive),
				get_shift_trace(self.HeldSprintKeys, pressed_keys)
			))
		end

		if not next(get_pressed_shift_keys()) then
			self:_reconcile_sprint(on_began, on_ended, "Heartbeat", nil, false)
		end
	end)
end

function PCInput:ResetHeldKeys(reason)
	print(string.format(
		"[ShiftTrace][PC][%s] ResetHeldKeys reason=%s activeBefore=%s",
		SHIFT_TRACE_VERSION,
		tostring(reason or "unspecified"),
		tostring(self.SprintSourceActive)
	))
	self.SprintSourceActive = false
	table.clear(self.HeldSprintKeys)
	self:_stop_sprint_monitor(reason or "ResetHeldKeys")
end

function PCInput:_start(on_began, on_ended)
	print(string.format(
		"[ShiftTrace][PC][%s] adapter started; GetKeysPressed reconciliation enabled",
		SHIFT_TRACE_VERSION
	))

	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:ResetHeldKeys("WindowFocusReleased")
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC][%s] InputBegan key=%s processed=%s before{%s}",
				SHIFT_TRACE_VERSION,
				tostring(input.KeyCode),
				tostring(game_processed),
				get_shift_trace(self.HeldSprintKeys, get_pressed_shift_keys())
			))
		end

		if game_processed then
			if is_shift then
				print(string.format(
					"[ShiftTrace][PC][%s] InputBegan ignored because gameProcessedEvent=true",
					SHIFT_TRACE_VERSION
				))
			end
			return
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if not action then
			return
		end

		if action == Actions.Sprint then
			self:_reconcile_sprint(on_began, on_ended, "InputBegan", input.KeyCode, true)
		else
			local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
			on_began(action, "PC", source_id)
		end
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC][%s] InputEnded key=%s processed=%s before{%s}",
				SHIFT_TRACE_VERSION,
				tostring(input.KeyCode),
				tostring(game_processed),
				get_shift_trace(self.HeldSprintKeys, get_pressed_shift_keys())
			))
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if not action then
			return
		end

		if action == Actions.Sprint then
			-- KeyCode on InputEnded has been observed to identify the opposite
			-- Shift. Rebuild held state from Roblox's current pressed-key list.
			self:_reconcile_sprint(on_began, on_ended, "InputEnded", input.KeyCode, false)
		else
			local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:Destroy()
	if self.Destroyed then
		return
	end

	self.Destroyed = true
	self:ResetHeldKeys("Destroy")
	self.Trove:Destroy()
end

return PCInput
