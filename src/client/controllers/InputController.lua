local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local PCInput = require(script.Parent.Parent.input.PC)
local MobileInput = require(script.Parent.Parent.input.Mobile)

local DEFAULT_INPUT_SOURCE = "Default"
-- Group concrete input types by device family so mouse/keyboard transitions
-- do not cancel each other, while switching to touch/gamepad releases stale holds.
local INPUT_SOURCES = {
	[Enum.UserInputType.Keyboard] = "PC",
	[Enum.UserInputType.MouseButton1] = "PC",
	[Enum.UserInputType.MouseButton2] = "PC",
	[Enum.UserInputType.MouseButton3] = "PC",
	[Enum.UserInputType.MouseMovement] = "PC",
	[Enum.UserInputType.MouseWheel] = "PC",
	[Enum.UserInputType.Touch] = "Mobile",
	[Enum.UserInputType.Gamepad1] = "Gamepad",
	[Enum.UserInputType.Gamepad2] = "Gamepad",
	[Enum.UserInputType.Gamepad3] = "Gamepad",
	[Enum.UserInputType.Gamepad4] = "Gamepad",
	[Enum.UserInputType.Gamepad5] = "Gamepad",
	[Enum.UserInputType.Gamepad6] = "Gamepad",
	[Enum.UserInputType.Gamepad7] = "Gamepad",
	[Enum.UserInputType.Gamepad8] = "Gamepad",
}

local function get_input_source(input_type)
	return INPUT_SOURCES[input_type]
end

local InputController = {}
InputController.__index = InputController

function InputController.new()
	local self = setmetatable({
		Trove = Trove.new(),
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
		SourcesDown = {},
		ActiveInputSource = get_input_source(UserInputService:GetLastInputType()),
	}, InputController)

	self.Trove:Add(self.ActionBegan)
	self.Trove:Add(self.ActionEnded)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function InputController:_start()
	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:_release_all()
	end)

	self.Trove:Connect(UserInputService.LastInputTypeChanged, function(input_type)
		self:_set_active_source(get_input_source(input_type))
	end)

	local began = function(action, source, source_id)
		self:_set_active_source(source)
		self:_began(action, source, source_id)
	end

	local ended = function(action, source, source_id)
		self:_ended(action, source, source_id)
	end

	self.PCInput = PCInput.new(began, ended)
	self.Trove:Add(self.PCInput)

	if UserInputService.TouchEnabled then
		self.Trove:Add(MobileInput.new(began, ended))
	end
end

function InputController:_began(action, source, source_id)
	source = source or DEFAULT_INPUT_SOURCE
	source_id = source_id or source

	if action == "Sprint" and source == "PC" then
		print(string.format(
			"[ShiftTrace][InputController] begin received sourceId=%s activeFamily=%s downBefore=%s",
			tostring(source_id),
			tostring(self.ActiveInputSource),
			tostring(self.Down[action])
		))
	end

	local sources = self.SourcesDown[action]
	if not sources then
		sources = {}
		self.SourcesDown[action] = sources
	end

	if sources[source_id] then
		return
	end

	sources[source_id] = source
	if self.Down[action] then
		return
	end

	self.Down[action] = true
	self.ActionBegan:Fire(action)
end

function InputController:_ended(action, source, source_id)
	source = source or DEFAULT_INPUT_SOURCE
	source_id = source_id or source

	local sources = self.SourcesDown[action]
	if action == "Sprint" and source == "PC" then
		local held = {}
		for held_id, held_source in pairs(sources or {}) do
			table.insert(held, tostring(held_id) .. ":" .. tostring(held_source))
		end
		table.sort(held)
		print(string.format(
			"[ShiftTrace][InputController] end received sourceId=%s matched=%s downBefore=%s heldBefore={%s}",
			tostring(source_id),
			tostring(sources ~= nil and sources[source_id] == source),
			tostring(self.Down[action]),
			table.concat(held, ",")
		))
	end

	if not sources or sources[source_id] ~= source then
		if action == "Sprint" and source == "PC" then
			print("[ShiftTrace][InputController] end ignored: source identity did not match")
		end
		return
	end

	sources[source_id] = nil
	if next(sources) ~= nil then
		if action == "Sprint" and source == "PC" then
			local held = {}
			for held_id, held_source in pairs(sources) do
				table.insert(held, tostring(held_id) .. ":" .. tostring(held_source))
			end
			table.sort(held)
			print(string.format("[ShiftTrace][InputController] source removed; Sprint remains down; heldAfter={%s}", table.concat(held, ",")))
		end
		return
	end

	self.SourcesDown[action] = nil
	self.Down[action] = nil
	if action == "Sprint" and source == "PC" then
		print("[ShiftTrace][InputController] last Sprint source removed; firing ActionEnded")
	end
	self.ActionEnded:Fire(action)
end

function InputController:_release_source(source)
	if not source then
		return
	end

	local affected_inputs = {}
	for action, sources in pairs(self.SourcesDown) do
		for source_id, source_kind in pairs(sources) do
			if source_kind == source then
				table.insert(affected_inputs, {
					Action = action,
					SourceId = source_id,
				})
			end
		end
	end

	for _, input in ipairs(affected_inputs) do
		self:_ended(input.Action, source, input.SourceId)
	end
end

function InputController:_set_active_source(source)
	if not source or source == self.ActiveInputSource then
		return
	end

	local previous_source = self.ActiveInputSource
	self.ActiveInputSource = source
	if previous_source == "PC" and self.PCInput then
		self.PCInput:ResetHeldKeys("InputFamilyChanged:" .. tostring(source))
	end
	self:_release_source(previous_source)
end

-- Release every held action when Roblox loses window focus. InputEnded is not
-- guaranteed to arrive after an application switch or an overlay transition.
function InputController:_release_all()
	local held_actions = {}
	for action in pairs(self.Down) do
		table.insert(held_actions, action)
	end

	for _, action in ipairs(held_actions) do
		self.SourcesDown[action] = nil
		self.Down[action] = nil
		self.ActionEnded:Fire(action)
	end
end

function InputController:IsDown(action)
	return self.Down[action] == true
end

function InputController:Destroy()
	self:_release_all()
	self.Trove:Destroy()
end

return InputController
