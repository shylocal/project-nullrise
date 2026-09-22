--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)

local Weapons = require(ReplicatedStorage.Shared.weapons)
local Fists = Weapons.Fists

type WeaponDefinition = typeof(Fists)

export type WeaponService = {
	Trove: typeof(Trove.new()),
	GetEquipped: (self: WeaponService, player: Player) -> WeaponDefinition?,
	Equip: (self: WeaponService, player: Player, weapon_id: string) -> boolean,
	Destroy: (self: WeaponService) -> (),
}

local WeaponService = {}
WeaponService.__index = WeaponService

function WeaponService.new(): WeaponService
	local self = setmetatable({
		Trove = Trove.new(),
		Equipped = {} :: { [Player]: WeaponDefinition },
	}, WeaponService)

	self:_start()

	return self
end

function WeaponService:_start()
	self.Trove:Connect(
		Players.PlayerAdded,
		function(player)
			self:_player_added(player)
		end
	)

	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player)
			self.Equipped[player] = nil
		end
	)

	for _, player in Players:GetPlayers() do
		self:_player_added(player)
	end
end

function WeaponService:_player_added(player: Player)
	if player.Parent ~= Players then
		return
	end

	self.Equipped[player] = Fists
end

function WeaponService:GetEquipped(player: Player): WeaponDefinition?
	return self.Equipped[player]
end

function WeaponService:Equip(player: Player, weapon_id: string): boolean
	if player.Parent ~= Players then
		return false
	end

	local weapon = Weapons[weapon_id]
	if not weapon then
		return false
	end

	self.Equipped[player] = weapon
	return true
end

function WeaponService:Destroy()
	self.Equipped = {}
	self.Trove:Destroy()
end

return WeaponService
