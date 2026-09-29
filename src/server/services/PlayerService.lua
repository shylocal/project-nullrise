local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local PlayerSession = require(script.Parent.PlayerSession)

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

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

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
	for _, player in Players:GetPlayers() do
		self:_player_added(player)
	end
end

function PlayerService:_player_added(player)
	if player.Parent ~= Players or self.Sessions[player] then
		return
	end

	local session = PlayerSession.new(player)
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
