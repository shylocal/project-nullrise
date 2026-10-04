--!strict
-- Players service stand-in. Add fires PlayerAdded with Parent already set to
-- this object; Remove fires PlayerRemoving before unparenting, as Roblox does.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.packages.Signal)

export type AddOptions = {
	UserId: number?,
	Name: string?,
	Ping: number?,
}

local FakePlayers = {}
FakePlayers.__index = FakePlayers

local FakePlayer = {}
FakePlayer.__index = FakePlayer

function FakePlayer.Kick(self: any, message: string?)
	self.Kicked = message or ""
end

function FakePlayer.GetNetworkPing(self: any): number
	return self.Ping
end

-- Mirrors Roblox ordering: CharacterRemoving for the old character, then
-- CharacterAdded for the new one. nil only removes the current character.
function FakePlayer.SetCharacter(self: any, character: Model?)
	local previous = self.Character
	if previous == character then
		return
	end
	if previous then
		self.CharacterRemoving:Fire(previous)
	end
	self.Character = character
	if character then
		self.CharacterAdded:Fire(character)
	end
end

function FakePlayers.new(): any
	return setmetatable({
		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
		_players = {} :: { any },
		_next_user_id = 1,
	}, FakePlayers)
end

function FakePlayers.GetPlayers(self: any): { any }
	return table.clone(self._players)
end

function FakePlayers.Add(self: any, opts: AddOptions?): any
	local options: AddOptions = opts or {}
	local user_id = options.UserId or self._next_user_id
	self._next_user_id = math.max(self._next_user_id, user_id) + 1

	local player = setmetatable({
		Name = options.Name or ("FakePlayer" .. tostring(user_id)),
		UserId = user_id,
		Parent = self,
		Character = nil :: Model?,
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
		Kicked = nil :: string?,
		Ping = options.Ping or 0,
	}, FakePlayer)

	table.insert(self._players, player)
	self.PlayerAdded:Fire(player)
	return player
end

function FakePlayers.Remove(self: any, player: any)
	local index = table.find(self._players, player)
	if not index then
		return
	end
	self.PlayerRemoving:Fire(player)
	table.remove(self._players, index)
	player.Parent = nil
end

return FakePlayers
