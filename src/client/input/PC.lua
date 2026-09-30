local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_SOURCE_ID = "KeyboardSprint"
local SHIFT_TRACE_VERSION = "diag-v9"
local SPRINT_KEYS = {
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift,
}

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

function PCInput._any_shift_down(is_key_down)
	return is_key_down(Enum.KeyCode.LeftShift) or is_key_down(Enum.KeyCode.RightShift)
end

function PCInput._any_shift_pressed(get_keys_pressed)
	for _, input in ipairs(get_keys_pressed()) do
		if is_sprint_key(input.KeyCode) then
			return true
		end
	end
	return false
end

local function get_shift_trace(held_keys)
	local pressed_keys = {}
	for _, input in ipairs(UserInputService:GetKeysPressed()) do
		if is_sprint_key(input.KeyCode) then
			table.insert(pressed_keys, tostring(input.KeyCode))
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

-- Track observed Shift begin edges, but treat InputEnded as an aggregate
-- release edge when its KeyCode does not match any tracked key. Roblox's
-- modifier-key pipeline can suppress one edge and report the opposite Shift.
function PCInput._begin_sprint_key(held_keys, key_code, on_began)
	if not is_sprint_key(key_code) then
		return false, false, next(held_keys) ~= nil
	end

	if held_keys[key_code] then
		return true, false, true
	end

	local was_active = next(held_keys) ~= nil
	held_keys[key_code] = true
	if not was_active then
		on_began(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	end

	return true, not was_active, true
end

function PCInput._end_sprint_key(held_keys, key_code, on_ended, source_active, any_shift_pressed)
	if not is_sprint_key(key_code) then
		return false, false, source_active or next(held_keys) ~= nil, nil, false
	end

	local was_active = source_active or next(held_keys) ~= nil
	local matched = held_keys[key_code] == true
	local removed_key = matched and key_code or nil

	-- InputEnded can identify the opposite Shift key. Preserve the aggregate
	-- Sprint source whenever GetKeysPressed still reports either Shift held.
	if any_shift_pressed then
		return true, matched, was_active, nil, false
	end

	table.clear(held_keys)
	local ended = was_active
	if ended then
		on_ended(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
	end

	return true, matched, false, removed_key, ended
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
			"[ShiftTrace][PC][%s] monitor stopping reason=%s active=%s before{%s}",
			SHIFT_TRACE_VERSION,
			tostring(reason or "unspecified"),
			tostring(self.SprintSourceActive),
			get_shift_trace(self.HeldSprintKeys)
		))
		self.SprintMonitor:Disconnect()
		self.SprintMonitor = nil
	end
end

function PCInput:_reconcile_sprint(on_ended, reason, event_key)
	local any_shift_pressed = PCInput._any_shift_pressed(function()
		return UserInputService:GetKeysPressed()
	end)
	local handled, matched, remains_active, removed_key, ended = PCInput._end_sprint_key(
		self.HeldSprintKeys,
		event_key or Enum.KeyCode.LeftShift,
		on_ended,
		self.SprintSourceActive,
		any_shift_pressed
	)

	self.SprintSourceActive = remains_active
	if not remains_active then
		self:_stop_sprint_monitor(reason)
	end

	print(string.format(
		"[ShiftTrace][PC][%s] reconcile reason=%s handled=%s matched=%s eventKey=%s removedKey=%s anyShiftPressed=%s remainsActive=%s ended=%s after{%s}",
		SHIFT_TRACE_VERSION,
		tostring(reason),
		tostring(handled),
		tostring(matched),
		tostring(event_key),
		tostring(removed_key),
		tostring(any_shift_pressed),
		tostring(remains_active),
		tostring(ended),
		get_shift_trace(self.HeldSprintKeys)
	))
end

function PCInput:_start_sprint_monitor(on_ended)
	if self.SprintMonitor or not self.SprintSourceActive then
		return
	end

	local trace_elapsed = 0
	print(string.format(
		"[ShiftTrace][PC][%s] monitor started active=%s before{%s}",
		SHIFT_TRACE_VERSION,
		tostring(self.SprintSourceActive),
		get_shift_trace(self.HeldSprintKeys)
	))

	self.SprintMonitor = RunService.Heartbeat:Connect(function(delta_time)
		if self.Destroyed or not self.SprintSourceActive then
			return
		end

		trace_elapsed += delta_time
		if trace_elapsed >= 0.5 then
			trace_elapsed = 0
			print(string.format(
				"[ShiftTrace][PC][%s] heartbeat monitor active=%s %s",
				SHIFT_TRACE_VERSION,
				tostring(self.SprintSourceActive),
				get_shift_trace(self.HeldSprintKeys)
			))
		end

		if not PCInput._any_shift_pressed(function()
			return UserInputService:GetKeysPressed()
		end) then
			self:_reconcile_sprint(on_ended, "HeartbeatBothShiftUp")
		end
	end)
end

function PCInput:ResetHeldKeys(reason)
	print(string.format(
		"[ShiftTrace][PC][%s] ResetHeldKeys reason=%s activeBefore=%s before{%s}",
		SHIFT_TRACE_VERSION,
		tostring(reason or "unspecified"),
		tostring(self.SprintSourceActive),
		get_shift_trace(self.HeldSprintKeys)
	))
	self.SprintSourceActive = false
	table.clear(self.HeldSprintKeys)
	self:_stop_sprint_monitor(reason or "ResetHeldKeys")
end

function PCInput:_start(on_began, on_ended)
	print(string.format(
		"[ShiftTrace][PC][%s] adapter started; aggregate Shift edge tracking enabled",
		SHIFT_TRACE_VERSION
	))

	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:ResetHeldKeys("WindowFocusReleased")
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC][%s] InputBegan key=%s type=%s processed=%s before{%s}",
				SHIFT_TRACE_VERSION,
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
				"[ShiftTrace][PC][%s] Sprint begin handled=%s began=%s key=%s aggregateSource=%s after{%s}",
				SHIFT_TRACE_VERSION,
				tostring(handled),
				tostring(began),
				tostring(input.KeyCode),
				SPRINT_SOURCE_ID,
				get_shift_trace(self.HeldSprintKeys)
			))
		else
			on_began(action, "PC", source_id)
		end
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
			-- InputEnded may run before GetKeysPressed has settled for this
			-- frame. Leave the aggregate source active here; the Heartbeat
			-- monitor performs the authoritative all-Shift-up check next frame.
			print(string.format(
				"[ShiftTrace][PC][%s] Shift InputEnded deferred to Heartbeat eventKey=%s active=%s",
				SHIFT_TRACE_VERSION,
				tostring(input.KeyCode),
				tostring(self.SprintSourceActive)
			))
		elseif action then
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
