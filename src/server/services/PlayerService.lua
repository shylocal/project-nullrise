local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Session = {}
Session.__index = Session

function Session.new(player)
	local self = setmetatable({
		Player = player,
		Character = nil,

		Trove = Trove.new(),
		CharacterTrove = nil,

		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
	}, Session)

	self.Trove:Add(self.CharacterAdded)
	self.Trove:Add(self.CharacterRemoving)

	self:_start()

	return self
end

function Session:_start()
	self.Trove:Connect(
		self.Player.CharacterAdded,
		function(character)
			self:_set_character(character)
		end
	)

	self.Trove:Connect(
		self.Player.CharacterRemoving,
		function(character)
			self:_remove_character(character)
		end
	)

	local character = self.Player.Character
	if character then
		self:_set_character(character)
	end
end

function Session:_set_character(character)
	if self.Character == character then
		return
	end

	self:_remove_character(self.Character)

	self.Character = character
	self.CharacterTrove = Trove.new()

	self.CharacterTrove:AttachToInstance(character)
	self.Trove:Add(self.CharacterTrove)

	self.CharacterAdded:Fire(character)
end

function Session:_remove_character(character)
	if not character or self.Character ~= character then
		return
	end

	self.CharacterRemoving:Fire(character)

	self.Character = nil

	if self.CharacterTrove then
		self.CharacterTrove:Destroy()
		self.CharacterTrove = nil
	end
end

function Session:Destroy()
	self.Character = nil

	if self.CharacterTrove then
		self.CharacterTrove:Destroy()
		self.CharacterTrove = nil
	end

	self.Trove:Destroy()
end

local PlayerService = {}
PlayerService.__index = PlayerService

function PlayerService.new()
	local self = setmetatable({
		Trove = Trove.new(),
		Sessions = {},

		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
	}, PlayerService)

	self.Trove:Add(self.PlayerAdded)
	self.Trove:Add(self.PlayerRemoving)

	self:_start()

	return self
end

function PlayerService:_start()
	self.Trove:Connect(
		Players.PlayerAdded,
		function(player)
			self:_player_added(player)
		end
	)

	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player)
			self:_player_removing(player)
		end
	)

	-- Connect first, then process the players already in the server.
	-- This closes the startup race between PlayerAdded and initialization.
	for _, player in Players:GetPlayers() do
		self:_player_added(player)
	end
end

function PlayerService:_player_added(player)
	if player.Parent ~= Players or self.Sessions[player] then
		return
	end

	local session = Session.new(player)
	self.Sessions[player] = session

	self.PlayerAdded:Fire(player, session)
end

function PlayerService:_player_removing(player)
	local session = self.Sessions[player]
	if not session then
		return
	end

	self.PlayerRemoving:Fire(player, session)

	self.Sessions[player] = nil
	session:Destroy()
end

function PlayerService:Get(player)
	return self.Sessions[player]
end

function PlayerService:GetPlayers()
	return Players:GetPlayers()
end

function PlayerService:Destroy()
	for player, session in pairs(self.Sessions) do
		self.Sessions[player] = nil
		session:Destroy()
	end

	self.Trove:Destroy()
end

return PlayerService
