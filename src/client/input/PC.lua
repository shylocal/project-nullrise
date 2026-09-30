local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_SOURCE_ID = "KeyboardSprint"

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

-- Temporary diagnostics for the reported simultaneous-Shift behavior.
local function get_shift_trace()
	return string.format(
		"physical[L=%s,R=%s]",
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

function PCInput._any_shift_down(is_key_down)
	return is_key_down(Enum.KeyCode.LeftShift) or is_key_down(Enum.KeyCode.RightShift)
end

function PCInput._begin_sprint(on_began)
	on_began(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
end

function PCInput._end_sprint(on_ended)
	on_ended(Actions.Sprint, "PC", SPRINT_SOURCE_ID)
end

function PCInput.new(on_began, on_ended)
	local self = setmetatable({
		Trove = Trove.new(),
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
			get_shift_trace()
		))
		self.SprintMonitor:Disconnect()
		self.SprintMonitor = nil
	else
		print(string.format(
			"[ShiftTrace][PC] monitor stop requested reason=%s but no monitor is connected",
			tostring(reason or "unspecified")
		))
	end
end

function PCInput:_finish_sprint(on_ended, reason)
	if not self.SprintSourceActive then
		return
	end

	self.SprintSourceActive = false
	self:_stop_sprint_monitor("SprintEnded:" .. tostring(reason))
	print(string.format(
		"[ShiftTrace][PC] Sprint source ended reason=%s %s",
		tostring(reason),
		get_shift_trace()
	))
	PCInput._end_sprint(on_ended)
end

function PCInput:_start_sprint_monitor(on_ended)
	if self.SprintMonitor then
		return
	end

	self.SprintSourceActive = true
	local traceElapsed = 0
	print(string.format(
		"[ShiftTrace][PC] monitor started active=%s %s",
		tostring(self.SprintSourceActive),
		get_shift_trace()
	))
	self.SprintMonitor = RunService.Heartbeat:Connect(function(deltaTime)
		if self.Destroyed or not self.SprintSourceActive then
			print(string.format(
				"[ShiftTrace][PC] monitor callback inactive destroyed=%s active=%s",
				tostring(self.Destroyed),
				tostring(self.SprintSourceActive)
			))
			return
		end

		local leftDown = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		local rightDown = UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		traceElapsed += deltaTime
		if traceElapsed >= 0.5 then
			traceElapsed = 0
			print(string.format(
				"[ShiftTrace][PC] heartbeat monitor active=%s trackedSource=%s physical[L=%s,R=%s]",
				tostring(self.SprintSourceActive),
				tostring(self.SprintSourceActive and "KeyboardSprint" or "none"),
				tostring(leftDown),
				tostring(rightDown)
			))
		end

		if not leftDown and not rightDown then
			print("[ShiftTrace][PC] Heartbeat observed both Shift keys up; reconciling Sprint")
			self:_finish_sprint(on_ended, "Heartbeat")
		end
	end)
end

function PCInput:_start(on_began, on_ended)
	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:ResetHeldKeys("WindowFocusReleased")
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC] InputBegan key=%s type=%s processed=%s %s",
				tostring(input.KeyCode),
				tostring(input.UserInputType),
				tostring(game_processed),
				get_shift_trace()
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
			PCInput._begin_sprint(on_began)
			self:_start_sprint_monitor(on_ended)
			print(string.format(
				"[ShiftTrace][PC] Sprint begin sent sourceId=%s %s",
				SPRINT_SOURCE_ID,
				get_shift_trace()
			))
		else
			on_began(action, "PC", source_id)
		end
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input)
		local is_shift = is_sprint_key(input.KeyCode)
		if is_shift then
			print(string.format(
				"[ShiftTrace][PC] InputEnded key=%s type=%s %s",
				tostring(input.KeyCode),
				tostring(input.UserInputType),
				get_shift_trace()
			))
		end

		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType

		if is_shift then
			-- Do not trust the event's Shift side: Roblox may report the other
			-- modifier or suppress one edge when both keys are held. The
			-- Heartbeat monitor ends the aggregate Sprint source only after
			-- neither physical Shift key remains down.
			if self.SprintSourceActive then
				print("[ShiftTrace][PC] Shift end observed; awaiting aggregate physical-key reconciliation")
			else
				print("[ShiftTrace][PC] Shift end observed while no Sprint source is active")
			end
		elseif action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:ResetHeldKeys(reason)
	print(string.format(
		"[ShiftTrace][PC] ResetHeldKeys reason=%s activeBefore=%s %s",
		tostring(reason or "unspecified"),
		tostring(self.SprintSourceActive),
		get_shift_trace()
	))
	self.SprintSourceActive = false
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
