--!strict
-- Centralizes logical input state across device adapters.
-- Adapters report (action, source family, physical source id); this module owns
-- deduplication, aggregate held state, focus-loss recovery, and lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Trove = require(script.Parent.Parent.ClientTrove)
local Signal = require(ReplicatedStorage.packages.Signal)

local PCInput = require(script.Parent.Parent.input.PC)
local MobileInput = require(script.Parent.Parent.input.Mobile)
local GamepadInput = require(script.Parent.Parent.input.Gamepad)

type Trove = Trove.Trove
type Signal = typeof(Signal.new())

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

-- A physical input: a KeyCode / UserInputType, a touch button name, or an
-- Instance (a GUI button).
export type SourceId = string | EnumItem | Instance
-- Adapters report (action, source family, physical source id). A missing
-- family defaults to "Default" and a missing id to the family.
export type Report = (action: string, source: string?, source_id: SourceId?) -> ()
-- A device adapter, or any destroyable fake in specs. An adapter may also
-- define an optional `ReleaseAll(self)`: the controller calls it on focus loss
-- so the adapter can drop internal held/latched state (PC's sprint latch)
-- without reporting; the controller has already released every action.
export type Adapter =
	PCInput.PCInput
	| MobileInput.MobileInput
	| GamepadInput.GamepadInput
	| { Destroy: (self: any) -> () }
-- An adapter factory receives the began/ended reporters and returns the
-- adapter, which the controller destroys with itself.
export type AdapterFactory = (began: Report, ended: Report) -> Adapter

export type AdapterDeps = {
	adapters: { AdapterFactory },
	-- An RBXScriptSignal (WindowFocusReleased) or a Signal in specs.
	focus_released: RBXScriptSignal | Signal,
	initial_source: string?,
}

-- What consumers (PlayerController, the character controllers) need from the
-- InputController. Method `self` is `any` so the controller and spec fakes
-- both satisfy it.
export type InputLike = {
	ActionBegan: Signal,
	ActionEnded: Signal,
	IsDown: (self: any, action: string) -> boolean,
}

type InputControllerFields = {
	Trove: Trove,
	-- (action)
	ActionBegan: Signal,
	-- (action)
	ActionEnded: Signal,
	-- SourcesDown[action][physical_source_id] = source_family.
	-- This is the sole source of truth; IsDown derives from its membership.
	SourcesDown: { [string]: { [SourceId]: string } },
	ActiveInputSource: string?,
	_adapters: { Adapter },
	_destroyed: boolean,
}

type Release = { action: string, source_id: SourceId }

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

export type InputController = typeof(setmetatable({} :: InputControllerFields, InputController))

-- Builds the controller over the device adapters available on this client.
function InputController.new(): InputController
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
function InputController.from_adapters(deps: AdapterDeps): InputController
	assert(typeof(deps) == "table", "InputController.from_adapters: deps must be a table")
	assert(typeof(deps.adapters) == "table", "InputController.from_adapters: missing dependency 'adapters'")
	assert(deps.focus_released ~= nil, "InputController.from_adapters: missing dependency 'focus_released'")

	local self = setmetatable({
		Trove = Trove.new(),
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		SourcesDown = {},
		ActiveInputSource = deps.initial_source,
		_adapters = {},
		_destroyed = false,
	} :: InputControllerFields, InputController)

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

function InputController._start(self: InputController, deps: AdapterDeps)
	self.Trove:Connect(deps.focus_released, function()
		self:_release_all()
	end)

	-- Device changes are committed only when an adapter reports a real bound
	-- action. LastInputTypeChanged also fires for passive mouse movement/drift.
	local function began(action: string, source: string?, source_id: SourceId?)
		if self._destroyed then
			return
		end
		self:_set_active_source(source)
		self:_began(action, source, source_id)
	end

	local function ended(action: string, source: string?, source_id: SourceId?)
		if self._destroyed then
			return
		end
		self:_ended(action, source, source_id)
	end

	for _, factory in ipairs(deps.adapters) do
		local adapter = factory(began, ended)
		table.insert(self._adapters, adapter)
		self.Trove:Add(adapter)
	end
end

function InputController._began(self: InputController, action: string, source: string?, source_id: SourceId?)
	local family = source or DEFAULT_SOURCE
	local id: SourceId = source_id or family

	assert(is_valid_action(action), "InputController: action must be a non-empty string")
	assert(is_valid_source(family), "InputController: source must be a non-empty string")
	assert(is_valid_source_id(id), "InputController: source_id must be a string, EnumItem, or Instance")

	local sources = self.SourcesDown[action]
	if not sources then
		sources = {}
		self.SourcesDown[action] = sources
	end

	-- Ignore repeat Begin events from the same physical input.
	if sources[id] ~= nil then
		return
	end

	local was_down = next(sources) ~= nil
	sources[id] = family
	if not was_down then
		self.ActionBegan:Fire(action)
	end
end

function InputController._ended(self: InputController, action: string, source: string?, source_id: SourceId?)
	local family = source or DEFAULT_SOURCE
	local id: SourceId = source_id or family

	if not is_valid_action(action) or not is_valid_source(family) or not is_valid_source_id(id) then
		return
	end

	local sources = self.SourcesDown[action]
	if not sources or sources[id] ~= family then
		return
	end

	sources[id] = nil
	if next(sources) == nil then
		self.SourcesDown[action] = nil
		self.ActionEnded:Fire(action)
	end
end

function InputController._release_source(self: InputController, source: string?)
	if not source then
		return
	end

	local releases: { Release } = {}
	for action, sources in pairs(self.SourcesDown) do
		for source_id, source_family in pairs(sources) do
			if source_family == source then
				table.insert(releases, { action = action, source_id = source_id })
			end
		end
	end

	-- Stable ordering makes simultaneous releases reproducible in tests/logs.
	table.sort(releases, function(a: Release, b: Release): boolean
		if a.action == b.action then
			return tostring(a.source_id) < tostring(b.source_id)
		end
		return a.action < b.action
	end)

	for _, release in ipairs(releases) do
		self:_ended(release.action, source, release.source_id)
	end
end

function InputController._set_active_source(self: InputController, source: string?)
	if not is_valid_source(source) or source == self.ActiveInputSource then
		return
	end

	local previous_source = self.ActiveInputSource
	self.ActiveInputSource = source
	self:_release_source(previous_source)
end

-- InputEnded may not arrive after focus changes, app switching, or overlays.
function InputController._release_all(self: InputController)
	-- Adapters that latch held state (PC's sprint) must forget it too, or the
	-- next press of that key is swallowed as a repeat.
	for _, adapter in ipairs(self._adapters) do
		-- ReleaseAll is optional and not part of every Adapter member's type.
		local release_all = (adapter :: any).ReleaseAll
		if type(release_all) == "function" then
			release_all(adapter)
		end
	end

	local actions: { string } = {}
	for action in pairs(self.SourcesDown) do
		table.insert(actions, action)
	end
	table.sort(actions)

	table.clear(self.SourcesDown)
	for _, action in ipairs(actions) do
		self.ActionEnded:Fire(action)
	end
end

function InputController.IsDown(self: InputController, action: string): boolean
	local sources = self.SourcesDown[action]
	return sources ~= nil and next(sources) ~= nil
end

function InputController.GetActiveSource(self: InputController): string?
	return self.ActiveInputSource
end

function InputController.Destroy(self: InputController)
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Emit final releases while listeners are still alive, then dispose resources.
	self:_release_all()
	self.Trove:Destroy()
end

return InputController
