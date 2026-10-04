-- One player's server-side lifetime: the current character, a Trove that
-- dies with the session, a Trove that dies with each character, and keyed
-- per-component state. Phase is written only by PlayerService.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

export type Phase = "Loading" | "Ready" | "Leaving"

local PlayerSession = {}
PlayerSession.__index = PlayerSession

local function destroy_state(state)
	if type(state) == "table" and type(state.Destroy) == "function" then
		state:Destroy()
	end
end

function PlayerSession.new(player)
	local self = setmetatable({
		Player = player,
		UserId = player.UserId,
		Phase = "Loading" :: Phase,
		Character = nil,

		Trove = Trove.new(),
		CharacterTrove = nil,

		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),

		_state = {},
		_destroyed = false,
	}, PlayerSession)

	self.Trove:Add(self.CharacterAdded)
	self.Trove:Add(self.CharacterRemoving)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function PlayerSession:_start()
	self.Trove:Connect(self.Player.CharacterAdded, function(character)
		self:_set_character(character)
	end)

	self.Trove:Connect(self.Player.CharacterRemoving, function(character)
		self:_remove_character(character)
	end)

	local character = self.Player.Character
	if character then
		self:_set_character(character)
	end
end

function PlayerSession:_set_character(character)
	if self._destroyed or self.Character == character then
		return
	end

	self:_remove_character(self.Character)

	local character_trove = Trove.new()
	self.Character = character
	self.CharacterTrove = character_trove

	-- The character can still be unparented when CharacterAdded fires, so the
	-- trove follows Destroying rather than AttachToInstance (which requires
	-- the instance to be inside the DataModel).
	character_trove:Connect(character.Destroying, function()
		self:_remove_character(character)
	end)

	self.CharacterAdded:Fire(character)
end

function PlayerSession:_remove_character(character)
	if not character or self.Character ~= character then
		return
	end

	-- Listeners see the character and its trove intact; both are released
	-- only after every CharacterRemoving handler ran.
	self.CharacterRemoving:Fire(character)

	if self.Character ~= character then
		return
	end

	local character_trove = self.CharacterTrove
	self.Character = nil
	self.CharacterTrove = nil

	if character_trove then
		character_trove:Destroy()
	end
end

-- Replaces the state stored under key. A previous, different state with a
-- Destroy method is destroyed. A destroyed session accepts no new state: the
-- given state is destroyed immediately, so a component that finishes loading
-- after the player left cannot leak it.
function PlayerSession:Set(key, state)
	assert(key ~= nil, "PlayerSession:Set: key must not be nil")

	if self._destroyed then
		destroy_state(state)
		return
	end

	local previous = self._state[key]
	self._state[key] = state

	if previous ~= nil and previous ~= state then
		destroy_state(previous)
	end
end

function PlayerSession:Get(key)
	if key == nil then
		return nil
	end
	return self._state[key]
end

function PlayerSession:Clear(key)
	if key == nil then
		return
	end

	local state = self._state[key]
	self._state[key] = nil
	destroy_state(state)
end

function PlayerSession:IsDestroyed()
	return self._destroyed
end

function PlayerSession:Destroy()
	if self._destroyed then
		return
	end

	if self.Character then
		self:_remove_character(self.Character)
	end

	self._destroyed = true

	local states = self._state
	self._state = {}
	for _, state in pairs(states) do
		local ok, err = pcall(destroy_state, state)
		if not ok then
			warn(("[PlayerSession] failed to destroy state for %s: %s"):format(
				tostring(self.Player.Name),
				tostring(err)
			))
		end
	end

	self.Trove:Destroy()
end

return PlayerSession
