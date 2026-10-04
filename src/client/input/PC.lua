--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Trove = require(script.Parent.Parent.ClientTrove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

type Trove = Trove.Trove

-- (action, source family, physical source id), as InputController.Report.
export type Report = (action: string, source: string, source_id: string | EnumItem) -> ()

type PCInputFields = {
	Trove: Trove,
	OnBegan: Report?,
	OnEnded: Report?,
	SprintActive: boolean,
	_destroyed: boolean,
}

local PCInput = {}
PCInput.__index = PCInput

export type PCInput = typeof(setmetatable({} :: PCInputFields, PCInput))

local SPRINT_BINDING = "ProjectNullriseSprint_LeftShift"

local SLOT_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
}

-- Keyed by UserInputType (mouse buttons) or KeyCode (keyboard keys).
local Bindings: { [EnumItem]: string } = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,
	[Enum.KeyCode.Space] = Actions.Jump,
	[Enum.KeyCode.W] = Actions.Forward,
	[Enum.KeyCode.S] = Actions.Backward,
	[Enum.KeyCode.A] = Actions.Left,
	[Enum.KeyCode.D] = Actions.Right,
}

-- Number keys select the slots Actions generates from Config.Inventory.MaxSlots.
for index, slot_action in ipairs(Actions.Slots) do
	local key_code = SLOT_KEYS[index]
	if key_code then
		Bindings[key_code] = slot_action
	end
end

PCInput.Bindings = Bindings

-- Keyboard keys are identified by KeyCode; mouse buttons by UserInputType.
local function source_id_of(input: InputObject): EnumItem
	if input.UserInputType == Enum.UserInputType.Keyboard then
		return input.KeyCode
	end
	return input.UserInputType
end

local function report(callback: Report?, action: string, source_id: string | EnumItem)
	if callback then
		callback(action, "PC", source_id)
	end
end

function PCInput.new(on_began: Report, on_ended: Report): PCInput
	assert(type(on_began) == "function", "PCInput requires on_began")
	assert(type(on_ended) == "function", "PCInput requires on_ended")

	local self = setmetatable({
		Trove = Trove.new(),
		OnBegan = on_began,
		OnEnded = on_ended,
		SprintActive = false,
		_destroyed = false,
	} :: PCInputFields, PCInput)

	local ok, err = xpcall(function()
		self:_start()
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function PCInput._set_sprint_active(self: PCInput, enabled: boolean)
	if self._destroyed or self.SprintActive == enabled then
		return
	end
	self.SprintActive = enabled
	if enabled then
		report(self.OnBegan, Actions.Sprint, "SprintToggle")
	else
		report(self.OnEnded, Actions.Sprint, "SprintToggle")
	end
end

function PCInput._on_sprint_input(
	self: PCInput,
	_action_name: string,
	input_state: Enum.UserInputState,
	input_object: InputObject?
): Enum.ContextActionResult
	-- ContextActionService can invoke this binding for other keys in some
	-- test/adaptor paths; only LeftShift is the configured sprint control.
	if input_object and input_object.KeyCode ~= Enum.KeyCode.LeftShift then
		return Enum.ContextActionResult.Pass
	end

	if input_state == Enum.UserInputState.Begin then
		self:_set_sprint_active(true)
	elseif input_state == Enum.UserInputState.End or input_state == Enum.UserInputState.Cancel then
		self:_set_sprint_active(false)
	end
	return Enum.ContextActionResult.Pass
end

function PCInput._start(self: PCInput)
	ContextActionService:UnbindAction(SPRINT_BINDING)
	ContextActionService:BindAction(
		SPRINT_BINDING,
		function(action_name: string, input_state: Enum.UserInputState, input_object: InputObject)
			return self:_on_sprint_input(action_name, input_state, input_object)
		end,
		false,
		Enum.KeyCode.LeftShift
	)
	self.Trove:Add(function()
		ContextActionService:UnbindAction(SPRINT_BINDING)
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input: InputObject, game_processed: boolean)
		if game_processed or input.KeyCode == Enum.KeyCode.LeftShift then
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then
			report(self.OnBegan, action, source_id_of(input))
		end
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.LeftShift then
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then
			report(self.OnEnded, action, source_id_of(input))
		end
	end)
end

function PCInput.Destroy(self: PCInput)
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self.SprintActive and self.OnEnded then
		self.SprintActive = false
		report(self.OnEnded, Actions.Sprint, "SprintToggle")
	end
	self.OnBegan = nil
	self.OnEnded = nil
	self.Trove:Destroy()
end

return PCInput
