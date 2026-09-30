--!strict
-- Centralizes logical input state across device adapters.
-- Adapters report (action, source family, physical source id); this module owns
-- deduplication, aggregate held state, focus-loss recovery, and lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("packages")
local Trove = require(Packages:WaitForChild("Trove"))
local Signal = require(Packages:WaitForChild("Signal"))

local PCInput = require(script.Parent.Parent.input.PC)
local MobileInput = require(script.Parent.Parent.input.Mobile)

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

local function sourceFromInputType(inputType: Enum.UserInputType): string?
	return INPUT_SOURCES[inputType]
end

local function isValidAction(action: any): boolean
	return typeof(action) == "string" and action ~= ""
end

local function isValidSource(source: any): boolean
	return typeof(source) == "string" and source ~= ""
end

local function isValidSourceId(sourceId: any): boolean
	local kind = typeof(sourceId)
	return (kind == "string" and sourceId ~= "")
		or kind == "EnumItem"
		or kind == "Instance"
end

local InputController = {}
InputController.__index = InputController

function InputController.new()
	local self = setmetatable({
		Trove = Trove.new(),
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		-- SourcesDown[action][physicalSourceId] = sourceFamily.
		-- This is the sole source of truth; IsDown derives from its membership.
		SourcesDown = {},
		ActiveInputSource = sourceFromInputType(UserInputService:GetLastInputType()),
		_Destroyed = false,
	}, InputController)

	self.Trove:Add(self.ActionBegan)
	self.Trove:Add(self.ActionEnded)

	local ok, err = xpcall(function()
		self:_start()
	end, debug.traceback)
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

	-- Device changes are committed only when an adapter reports a real bound
	-- action. LastInputTypeChanged also fires for passive mouse movement/drift.
	local function began(action, source, sourceId)
		if self._Destroyed then
			return
		end
		self:_set_active_source(source)
		self:_began(action, source, sourceId)
	end

	local function ended(action, source, sourceId)
		if self._Destroyed then
			return
		end
		self:_ended(action, source, sourceId)
	end

	self.Trove:Add(PCInput.new(began, ended))
	if UserInputService.TouchEnabled then
		self.Trove:Add(MobileInput.new(began, ended))
	end
end

function InputController:_began(action, source, sourceId)
	source = source or DEFAULT_SOURCE
	sourceId = sourceId or source

	assert(isValidAction(action), "InputController: action must be a non-empty string")
	assert(isValidSource(source), "InputController: source must be a non-empty string")
	assert(isValidSourceId(sourceId), "InputController: sourceId must be a string, EnumItem, or Instance")

	local sources = self.SourcesDown[action]
	if not sources then
		sources = {}
		self.SourcesDown[action] = sources
	end

	-- Ignore repeat Begin events from the same physical input.
	if sources[sourceId] ~= nil then
		return
	end

	local wasDown = next(sources) ~= nil
	sources[sourceId] = source
	if not wasDown then
		self.ActionBegan:Fire(action)
	end
end

function InputController:_ended(action, source, sourceId)
	source = source or DEFAULT_SOURCE
	sourceId = sourceId or source

	if not isValidAction(action) or not isValidSource(source) or not isValidSourceId(sourceId) then
		return
	end

	local sources = self.SourcesDown[action]
	if not sources or sources[sourceId] ~= source then
		return
	end

	sources[sourceId] = nil
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
		for sourceId, sourceFamily in pairs(sources) do
			if sourceFamily == source then
				table.insert(releases, { action, sourceId })
			end
		end
	end

	-- Stable ordering makes simultaneous releases reproducible in tests/logs.
	table.sort(releases, function(a, b)
		local actionA, actionB = tostring(a[1]), tostring(b[1])
		if actionA == actionB then
			return tostring(a[2]) < tostring(b[2])
		end
		return actionA < actionB
	end)

	for _, release in ipairs(releases) do
		self:_ended(release[1], source, release[2])
	end
end

function InputController:_set_active_source(source)
	if not isValidSource(source) or source == self.ActiveInputSource then
		return
	end

	local previousSource = self.ActiveInputSource
	self.ActiveInputSource = source
	self:_release_source(previousSource)
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
	if self._Destroyed then
		return
	end
	self._Destroyed = true

	-- Emit final releases while listeners are still alive, then dispose resources.
	self:_release_all()
	self.Trove:Destroy()
end

return InputController
