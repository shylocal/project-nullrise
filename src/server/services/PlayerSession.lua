local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local PlayerSession = {}
PlayerSession.__index = PlayerSession

function PlayerSession.new(player)
	local self = setmetatable({
		Player = player,
		Character = nil,

		Trove = Trove.new(),
		CharacterTrove = nil,

		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
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

function PlayerSession:_set_character(character)
	if self.Character == character then
		return
	end

	self:_remove_character(self.Character)

	self.Character = character
	self.CharacterTrove = Trove.new()
	self.CharacterTrove:AttachToInstance(character)

	self.CharacterAdded:Fire(character)
end

function PlayerSession:_remove_character(character)
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

function PlayerSession:Destroy()
	if self.Character then
		self:_remove_character(self.Character)
	end

	self.Trove:Destroy()
end

return PlayerSession
