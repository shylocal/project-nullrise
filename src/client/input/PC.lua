local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_SOURCE_ID = "KeyboardSprint"
local SHIFT_TRACE_VERSION = "diag-v5"
local SPRINT_KEYS = {
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift,
}

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

-- GetKeysPressed provides a fresh list of InputObjects that Roblox currently
-- considers pressed. Keep IsKeyDown in diagnostics to compare both views.
local function get_pressed_shift_keys()
	local pressed = {}
	for _, input in ipairs(UserInputService:GetKeysPressed()) do
		if is_sprint_key(input.KeyCode) then
			pressed[input.KeyCode] = true
		end
	end
	return pressed
end

local function get_shift_trace(held_keys)
	local pressed = get_pressed_shift_keys()
	local pressed_keys = {}
	for _, key_code in ipairs(SPRINT_KEYS) do
		if pressed[key_code] then
			table.insert(pressed_keys, tostring(key_code))
		end
	end

	return string.format(
		"tracked[L=%s,R=%s] IsKeyDown[L=%s,R=%s] GetKeysPressed={%s}",
		tostring(held_keys[Enum.KeyCode.LeftShift] == true),
		tostring(held_keys[Enum.KeyCode.RightShift] == true),
		tostring(UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)),
		tostring(UserInputService:IsKeyDown(Enum.KeyCode.RightShift)),
		table.concat(pressed_keys, ",")
	)
end

local function is_shift_pressed(key_code, pressed_keys)
	return pressed_keys[key_code] == true
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

function PCInput._begin_sprint_key(held_keys, key_code, on_began)
	if not is_sprint_key(key_code) then
		return false, false, next(held_keys) ~= nil
	end

	local was_active = next(held_keys) ~= nil
	held_keys[key_code] = true
	if not was_active then
		on_began(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	end
	return true, not was_active, true
end

-- Query both physical modifier keys instead of trusting InputEnded's key
-- identity. Roblox may report the opposite Shift key or omit an edge.
function PCInput._reconcile_sprint_keys(held_keys, is_key_down, on_ended)
	local was_active = next(held_keys) ~= nil
	for _, key_code in ipairs(SPRINT_KEYS) do
		if is_key_down(key_code) then
			held_keys[key_code] = true
		else
			held_keys[key_code] = nil
		end
	end

	local remains_active = next(held_keys) ~= nil
	if was_active and not remains_active then
		on_ended(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	end
	return remains_active
end

function PCInput._end_sprint_key(held_keys, key_code, on_ended, is_key_down)
	if not is_sprint_key(key_code) then
		return false, nil, next(held_keys) ~= nil
	end

	-- Modifier-key events can identify the opposite Shift key, while Roblox's
	-- queried state may keep the released side stuck as down. If the event has
	-- no matching tracked key and exactly one Shift source remains, treat this
	-- unmatched end as the release of that remaining aggregate Sprint hold.
	if held_keys[key_code] ~= true then
		local tracked_count = 0
		local only_tracked_key = nil
		for _, sprint_key in ipairs(SPRINT_KEYS) do
			if held_keys[sprint_key] then
				tracked_count += 1
				only_tracked_key = sprint_key
			end
		end

		if tracked_count == 1 then
			held_keys[only_tracked_key] = nil
			on_ended(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
			return true, only_tracked_key, false
		end
	end

	local remains_active = PCInput._reconcile_sprint_keys(held_keys, is_key_down, on_ended)
	return true, key_code, remains_active
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
			"[ShiftTrace][PC] monitor stopping reason=%s active=%s %s",
			tostring(reason or "unspecified"),
			tostring(self.SprintSourceActive),
			get_shift_trace(self.HeldSprintKeys)
		))
		self.SprintMonitor:Disconnect()
		self.SprintMonitor = nil
	end
end

function PCInput:_reconcile_sprint(on_ended, reason)
	if not self.SprintSourceActive then
		return false
	end

	local was_active = self.SprintSourceActive
	local pressed_keys = get_pressed_shift_keys()
	local remains_active = PCInput._reconcile_sprint_keys(
		self.HeldSprintKeys,
		function(key_code)
			return is_shift_pressed(key_code, pressed_keys)
		end,
		on_ended
	)
	self.SprintSourceActive = remains_active

	if was_active and not remains_active then
		self:_stop_sprint_monitor(reason or "PhysicalState")
		print(string.format(
			"[ShiftTrace][PC] Sprint source ended reason=%s %s",
			tostring(reason or "PhysicalState"),
			get_shift_trace(self.HeldSprintKeys)
		))
	end
	return remains_active
end

function PCInput:_start_sprint_monitor(on_ended)
	if self.SprintMonitor then
		return
	end

	self.SprintSourceActive = true
	local traceElapsed = 0
	print(string.format(
		"[ShiftTrace][PC] monitor started %s",
		get_shift_trace(self.HeldSprintKeys)
	))
	self.SprintMonitor = RunService.Heartbeat:Connect(function(delta_time)
		if self.Destroyed or not self.SprintSourceActive then
			return
		end

		traceElapsed += delta_time
		if traceElapsed >= 0.5 then
			traceElapsed = 0
			print(string.format(
				"[ShiftTrace][PC] heartbeat active=%s %s",
				tostring(self.SprintSourceActive),
				get_shift_trace(self.HeldSprintKeys)
			))
		end

		self:_reconcile_sprint(on_ended, "Heartbeat")
	end)
end

function PCInput:_start(on_began, on_ended)
	print(string.format(
		"[ShiftTrace][PC][%s] adapter started; Shift diagnostics include InputBegan, InputChanged, InputEnded, state snapshots, and monitor lifecycle",
		SHIFT_TRACE_VERSION
	))

	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:ResetHeldKeys("WindowFocusReleased")
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
			local handled, began, remains_active = PCInput._begin_sprint_key(
				self.HeldSprintKeys,
				input.KeyCode,
				on_began
			)
			self.SprintSourceActive = remains_active
			self:_start_sprint_monitor(on_ended)
			print(string.format(
				"[ShiftTrace][PC] Sprint begin handled=%s began=%s sourceId=%s remainsActive=%s after{%s}",
				tostring(handled),
				tostring(began),
				SPRINT_SOURCE_ID,
				tostring(remains_active),
				get_shift_trace(self.HeldSprintKeys)
			))
		else
			on_began(action, "PC", source_id)
		end
	end)

	self.Trove:Connect(UserInputService.InputChanged, function(input, game_processed)
		if not is_sprint_key(input.KeyCode) then
			return
		end

		print(string.format(
			"[ShiftTrace][PC][%s] InputChanged key=%s type=%s state=%s processed=%s %s",
			SHIFT_TRACE_VERSION,
			tostring(input.KeyCode),
			tostring(input.UserInputType),
			tostring(input.UserInputState),
			tostring(game_processed),
			get_shift_trace(self.HeldSprintKeys)
		))
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC][%s] InputEnded key=%s type=%s processed=%s before{%s}",
				SHIFT_TRACE_VERSION,
				tostring(input.KeyCode),
				tostring(input.UserInputType),
				tostring(game_processed),
				get_shift_trace(self.HeldSprintKeys)
			))
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType

		if is_shift then
			local pressed_keys = get_pressed_shift_keys()
			local handled, released_key, remains_active = PCInput._end_sprint_key(
				self.HeldSprintKeys,
				input.KeyCode,
				on_ended,
				function(key_code)
					return is_shift_pressed(key_code, pressed_keys)
				end
			)
			self.SprintSourceActive = remains_active
			if not remains_active then
				self:_stop_sprint_monitor("InputEnded")
			end
			print(string.format(
				"[ShiftTrace][PC] Sprint end observed handled=%s eventKey=%s sampledKey=%s remainsActive=%s after{%s}",
				tostring(handled),
				tostring(input.KeyCode),
				tostring(released_key),
				tostring(remains_active),
				get_shift_trace(self.HeldSprintKeys)
			))
		elseif action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:ResetHeldKeys(reason)
	print(string.format(
		"[ShiftTrace][PC] ResetHeldKeys reason=%s activeBefore=%s before{%s}",
		tostring(reason or "unspecified"),
		tostring(self.SprintSourceActive),
		get_shift_trace(self.HeldSprintKeys)
	))
	self.SprintSourceActive = false
	table.clear(self.HeldSprintKeys)
	self:_stop_sprint_monitor(reason or "ResetHeldKeys")
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
