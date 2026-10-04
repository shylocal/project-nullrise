--!strict
-- "Blocked until released" latches for held inputs. A latch stays blocked
-- until its action is no longer held; override handles attached to a latch
-- are popped when it releases. The Jump latch carries the disabled-jump
-- override left behind by a mantle or a completed vault, so native jumping
-- returns only once Space is let go.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.shared.input.Actions)

local CharacterStateModule = require(script.Parent.Parent.CharacterState)

export type Name = "Forward" | "Jump"
type Handle = CharacterStateModule.Handle
-- Method `self` is `any` so InputController and spec fakes both fit.
type InputLike = { IsDown: (self: any, action: string) -> boolean }

local ACTION_OF: { [string]: string } = {
	Forward = Actions.Forward,
	Jump = Actions.Jump,
}

local InputLatch = {}
InputLatch.__index = InputLatch

export type InputLatch = typeof(setmetatable(
	{} :: {
		_blocked: { [string]: { Handle } },
	},
	InputLatch
))

local function assert_name(name: any)
	if ACTION_OF[name] == nil then
		error(("InputLatch: unknown latch '%s'"):format(tostring(name)), 3)
	end
end

function InputLatch.new(): InputLatch
	return setmetatable({
		_blocked = {},
	}, InputLatch)
end

-- Blocks the latch (or keeps it blocked) and attaches any handles to it.
function InputLatch.Block(self: InputLatch, name: Name, handles: { Handle }?)
	assert_name(name)
	local attached = self._blocked[name]
	if not attached then
		attached = {}
		self._blocked[name] = attached
	end
	if handles then
		for _, handle in handles do
			table.insert(attached, handle)
		end
	end
end

-- Unblocks the latch and pops every handle attached to it.
function InputLatch.Release(self: InputLatch, name: Name)
	assert_name(name)
	local attached = self._blocked[name]
	if not attached then
		return
	end
	self._blocked[name] = nil
	for _, handle in attached do
		handle:Pop()
	end
end

function InputLatch.IsBlocked(self: InputLatch, name: Name): boolean
	assert_name(name)
	return self._blocked[name] ~= nil
end

-- Releases every latch whose action is no longer held. Recovers from a lost
-- ActionEnded (focus changes or UI capture); called each step.
function InputLatch.Sync(self: InputLatch, input: InputLike)
	for name in ACTION_OF do
		if self._blocked[name] and not input:IsDown(ACTION_OF[name]) then
			self:Release(name :: Name)
		end
	end
end

function InputLatch.Destroy(self: InputLatch)
	for name in ACTION_OF do
		self:Release(name :: Name)
	end
end

return InputLatch
