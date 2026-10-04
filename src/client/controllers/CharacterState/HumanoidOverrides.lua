--!strict
-- Layered, owner-tracked overrides of Humanoid properties.
--
-- Each property has its own stack of handles. The effective value is the value
-- of the most recently pushed live handle. The base value is captured when the
-- first handle for a property is pushed and written back when that property's
-- stack becomes empty again (only while the Humanoid is still parented).
-- WalkSpeed is deliberately not managed here: MovementController is its sole
-- writer.
local HumanoidOverrides = {}
HumanoidOverrides.__index = HumanoidOverrides

local Handle = {}
Handle.__index = Handle

export type Property = "AutoRotate" | "PlatformStand" | "HipHeight" | "JumpPower" | "JumpHeight" | "JumpingEnabled"

local PROPERTIES: { [string]: boolean } = {
	AutoRotate = true,
	PlatformStand = true,
	HipHeight = true,
	JumpPower = true,
	JumpHeight = true,
	JumpingEnabled = true,
}

export type Handle = typeof(setmetatable(
	{} :: {
		Owner: string,
		Values: { [string]: any },
		_overrides: any,
		_popped: boolean,
	},
	Handle
))

export type HumanoidOverrides = typeof(setmetatable(
	{} :: {
		Humanoid: Humanoid,
		_stacks: { [string]: { Handle } },
		_bases: { [string]: any },
		_destroyed: boolean,
	},
	HumanoidOverrides
))

local function read_property(humanoid: Humanoid, property: string): any
	if property == "JumpingEnabled" then
		return humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	end
	-- Indexed by a validated property name; the engine boundary is untyped.
	return (humanoid :: any)[property]
end

local function write_property(humanoid: Humanoid, property: string, value: any)
	if property == "JumpingEnabled" then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, value)
	else
		(humanoid :: any)[property] = value
	end
end

local function assert_property(property: any)
	if type(property) ~= "string" or not PROPERTIES[property] then
		error(("HumanoidOverrides: unsupported property %s"):format(tostring(property)), 3)
	end
end

function HumanoidOverrides.new(humanoid: Humanoid): HumanoidOverrides
	assert(typeof(humanoid) == "Instance" and humanoid:IsA("Humanoid"), "HumanoidOverrides.new: expected a Humanoid")
	return setmetatable({
		Humanoid = humanoid,
		_stacks = {},
		_bases = {},
		_destroyed = false,
	}, HumanoidOverrides)
end

function HumanoidOverrides.Push(self: HumanoidOverrides, owner: string, props: { [Property]: any }): Handle
	if self._destroyed then
		error("HumanoidOverrides:Push called after Destroy", 2)
	end
	for property in props do
		assert_property(property)
	end

	local handle = setmetatable({
		Owner = owner,
		Values = {},
		_overrides = self,
		_popped = false,
	}, Handle)

	for property, value in (props :: any) :: { [string]: any } do
		local stack = self._stacks[property]
		if not stack then
			stack = {}
			self._stacks[property] = stack
		end
		if #stack == 0 then
			self._bases[property] = read_property(self.Humanoid, property)
		end
		table.insert(stack, handle)
		handle.Values[property] = value
		write_property(self.Humanoid, property, value)
	end

	return handle
end

-- The value captured when the property's stack was empty, or the current
-- value when nothing overrides it.
function HumanoidOverrides.Base(self: HumanoidOverrides, property: Property): any
	assert_property(property)
	local stack = self._stacks[property]
	if stack and #stack > 0 then
		return self._bases[property]
	end
	return read_property(self.Humanoid, property)
end

-- The value currently in effect for a property according to this stack.
function HumanoidOverrides.Effective(self: HumanoidOverrides, property: Property): any
	assert_property(property)
	local stack = self._stacks[property]
	local top = stack and stack[#stack]
	if top then
		return top.Values[property]
	end
	return read_property(self.Humanoid, property)
end

function HumanoidOverrides._pop_property(self: HumanoidOverrides, handle: Handle, property: string)
	local stack = self._stacks[property]
	if not stack then
		return
	end
	local index = table.find(stack, handle)
	if not index then
		return
	end
	local was_top = index == #stack
	table.remove(stack, index)

	local humanoid = self.Humanoid
	if #stack == 0 then
		local base = self._bases[property]
		self._bases[property] = nil
		if humanoid.Parent ~= nil then
			write_property(humanoid, property, base)
		end
	elseif was_top then
		write_property(humanoid, property, stack[#stack].Values[property])
	end
end

function HumanoidOverrides.Destroy(self: HumanoidOverrides)
	if self._destroyed then
		return
	end
	-- Pop newest first so each property unwinds through its own stack order.
	local handles: { Handle } = {}
	local seen: { [Handle]: boolean } = {}
	for _, stack in self._stacks do
		for _, handle in stack do
			if not seen[handle] then
				seen[handle] = true
				table.insert(handles, handle)
			end
		end
	end
	for index = #handles, 1, -1 do
		handles[index]:Pop()
	end
	self._destroyed = true
end

-- Changes one property this handle pushed. Writes through only when this
-- handle is the property's most recent live handle.
function Handle.Set(self: Handle, property: Property, value: any)
	if self._popped then
		return
	end
	if self.Values[property] == nil then
		error(("HumanoidOverrides: handle '%s' did not push %s"):format(self.Owner, tostring(property)), 2)
	end
	self.Values[property] = value
	local overrides = self._overrides :: HumanoidOverrides
	local stack = overrides._stacks[property]
	if stack and stack[#stack] == self then
		write_property(overrides.Humanoid, property, value)
	end
end

function Handle.IsLive(self: Handle): boolean
	return not self._popped
end

function Handle.Pop(self: Handle)
	if self._popped then
		return
	end
	self._popped = true
	local overrides = self._overrides :: HumanoidOverrides
	for property in self.Values do
		overrides:_pop_property(self, property)
	end
end

return HumanoidOverrides
