local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_BINDING = "ProjectNullriseSprint_LeftShift"

local Bindings = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,
	[Enum.KeyCode.Space] = Actions.Jump,
	[Enum.KeyCode.W] = Actions.Forward,
	[Enum.KeyCode.S] = Actions.Backward,
	[Enum.KeyCode.A] = Actions.Left,
	[Enum.KeyCode.D] = Actions.Right,
	[Enum.KeyCode.One] = Actions.Slot1,
	[Enum.KeyCode.Two] = Actions.Slot2,
}

function PCInput.new(on_began, on_ended)
	assert(type(on_began) == "function", "PCInput requires on_began")
	assert(type(on_ended) == "function", "PCInput requires on_ended")

	local self = setmetatable({
		Trove = Trove.new(),
		OnBegan = on_began,
		OnEnded = on_ended,
		SprintActive = false,
		_destroyed = false,
	}, PCInput)

	local ok, err = xpcall(function()
		self:_start()
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function PCInput:_set_sprint_active(enabled)
	if self._destroyed or self.SprintActive == enabled then
		return
	end
	self.SprintActive = enabled
	if enabled then
		self.OnBegan(Actions.Sprint, "PC", "SprintToggle")
	else
		self.OnEnded(Actions.Sprint, "PC", "SprintToggle")
	end
end

function PCInput:_on_sprint_input(_, input_state, input_object)
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

function PCInput:_start()
	ContextActionService:UnbindAction(SPRINT_BINDING)
	ContextActionService:BindAction(SPRINT_BINDING, function(...)
		return self:_on_sprint_input(...)
	end, false, Enum.KeyCode.LeftShift)
	self.Trove:Add(function()
		ContextActionService:UnbindAction(SPRINT_BINDING)
	end)

	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		if game_processed or input.KeyCode == Enum.KeyCode.LeftShift then
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then
			local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
			self.OnBegan(action, "PC", source_id)
		end
	end)

	self.Trove:Connect(UserInputService.InputEnded, function(input)
		if input.KeyCode == Enum.KeyCode.LeftShift then
			return
		end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		if action then
			local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
			self.OnEnded(action, "PC", source_id)
		end
	end)
end

function PCInput:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self.SprintActive and self.OnEnded then
		self.SprintActive = false
		self.OnEnded(Actions.Sprint, "PC", "SprintToggle")
	end
	self.OnBegan = nil
	self.OnEnded = nil
	self.Trove:Destroy()
end

return PCInput
