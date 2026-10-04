--!strict
-- Centralizes logical input state across device adapters.
-- Adapters report (action, source family, physical source id); this module owns
-- deduplication, aggregate held state, focus-loss recovery, and lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Signal = require(ReplicatedStorage.packages.Signal)

local PCInput = require(script.Parent.Parent.input.PC)
local MobileInput = require(script.Parent.Parent.input.Mobile)
local GamepadInput = require(script.Parent.Parent.input.Gamepad)

local DEFAULT_SOURCE = "Default"

local INPUT_SOURCES: { [Enum.UserInputType]: string } = {
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

export type Report = (action: any, source: any, source_id: any) -> ()
-- An adapter factory receives the began/ended reporters and returns the
-- adapter, which the controller destroys with itself.
export type AdapterFactory = (began: Report, ended: Report) -> any

export type AdapterDeps = {
	adapters: { AdapterFactory },
	focus_released: any,
	initial_source: string?,
}

local function source_from_input_type(input_type: Enum.UserInputType): string?
	return INPUT_SOURCES[input_type]
end

local function is_valid_action(action: any): boolean
	return typeof(action) == "string" and action ~= ""
end

local function is_valid_source(source: any): boolean
	return typeof(source) == "string" and source ~= ""
end

local function is_valid_source_id(source_id: any): boolean
	local kind = typeof(source_id)
	return (kind == "string" and source_id ~= "")
		or kind == "EnumItem"
		or kind == "Instance"
end

local InputController = {}
InputController.__index = InputController

-- Builds the controller over the device adapters available on this client.
function InputController.new()
	local adapters: { AdapterFactory } = { PCInput.new }
	if UserInputService.TouchEnabled then
		table.insert(adapters, MobileInput.new)
	end
	table.insert(adapters, GamepadInput.new)

	return InputController.from_adapters({
		adapters = adapters,
		focus_released = UserInputService.WindowFocusReleased,
		initial_source = source_from_input_type(UserInputService:GetLastInputType()),
	})
end

-- Builds the controller over explicit adapters and a focus-loss signal. Specs
-- use this with fake adapters; `new` uses it with the real devices.
function InputController.from_adapters(deps: AdapterDeps)
	assert(typeof(deps) == "table", "InputController.from_adapters: deps must be a table")
	assert(typeof(deps.adapters) == "table", "InputController.from_adapters: missing dependency 'adapters'")
	assert(deps.focus_released ~= nil, "InputController.from_adapters: missing dependency 'focus_released'")

	local self = setmetatable({
		Trove = Trove.new(),
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		-- SourcesDown[action][physical_source_id] = source_family.
		-- This is the sole source of truth; IsDown derives from its membership.
		SourcesDown = {},
		ActiveInputSource = deps.initial_source,
		_destroyed = false,
	}, InputController)

	self.Trove:Add(self.ActionBegan)
	self.Trove:Add(self.ActionEnded)

	local ok, err = xpcall(function()
		self:_start(deps)
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function InputController:_start(deps: AdapterDeps)
	self.Trove:Connect(deps.focus_released, function()
		self:_release_all()
	end)

	-- Device changes are committed only when an adapter reports a real bound
	-- action. LastInputTypeChanged also fires for passive mouse movement/drift.
	local function began(action, source, source_id)
		if self._destroyed then
			return
		end
		self:_set_active_source(source)
		self:_began(action, source, source_id)
	end

	local function ended(action, source, source_id)
		if self._destroyed then
			return
		end
		self:_ended(action, source, source_id)
	end

	for _, factory in ipairs(deps.adapters) do
		self.Trove:Add(factory(began, ended))
	end
end

function InputController:_began(action, source, source_id)
	source = source or DEFAULT_SOURCE
	source_id = source_id or source

	assert(is_valid_action(action), "InputController: action must be a non-empty string")
	assert(is_valid_source(source), "InputController: source must be a non-empty string")
	assert(is_valid_source_id(source_id), "InputController: source_id must be a string, EnumItem, or Instance")

	local sources = self.SourcesDown[action]
	if not sources then
		sources = {}
		self.SourcesDown[action] = sources
	end

	-- Ignore repeat Begin events from the same physical input.
	if sources[source_id] ~= nil then
		return
	end

	local was_down = next(sources) ~= nil
	sources[source_id] = source
	if not was_down then
		self.ActionBegan:Fire(action)
	end
end

function InputController:_ended(action, source, source_id)
	source = source or DEFAULT_SOURCE
	source_id = source_id or source

	if not is_valid_action(action) or not is_valid_source(source) or not is_valid_source_id(source_id) then
		return
	end

	local sources = self.SourcesDown[action]
	if not sources or sources[source_id] ~= source then
		return
	end

	sources[source_id] = nil
	if next(sources) == nil then
		self.SourcesDown[action] = nil
		self.ActionEnded:Fire(action)
	end
end

function InputController:_release_source(source)
	if not source then
		return
	end

	local releases = {}
	for action, sources in pairs(self.SourcesDown) do
		for source_id, source_family in pairs(sources) do
			if source_family == source then
				table.insert(releases, { action, source_id })
			end
		end
	end

	-- Stable ordering makes simultaneous releases reproducible in tests/logs.
	table.sort(releases, function(a, b)
		local action_a, action_b = tostring(a[1]), tostring(b[1])
		if action_a == action_b then
			return tostring(a[2]) < tostring(b[2])
		end
		return action_a < action_b
	end)

	for _, release in ipairs(releases) do
		self:_ended(release[1], source, release[2])
	end
end

function InputController:_set_active_source(source)
	if not is_valid_source(source) or source == self.ActiveInputSource then
		return
	end

	local previous_source = self.ActiveInputSource
	self.ActiveInputSource = source
	self:_release_source(previous_source)
end

-- InputEnded may not arrive after focus changes, app switching, or overlays.
function InputController:_release_all()
	local actions = {}
	for action in pairs(self.SourcesDown) do
		table.insert(actions, action)
	end
	table.sort(actions, function(a, b)
		return tostring(a) < tostring(b)
	end)

	table.clear(self.SourcesDown)
	for _, action in ipairs(actions) do
		self.ActionEnded:Fire(action)
	end
end

function InputController:IsDown(action)
	local sources = self.SourcesDown[action]
	return sources ~= nil and next(sources) ~= nil
end

function InputController:GetActiveSource()
	return self.ActiveInputSource
end

function InputController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Emit final releases while listeners are still alive, then dispose resources.
	self:_release_all()
	self.Trove:Destroy()
end

return InputController
