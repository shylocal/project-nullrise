local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local Fists = require(WeaponsFolder.Fists)

local WeaponService = {}
WeaponService.__index = WeaponService

function WeaponService.new()
	local self = setmetatable({
		Trove = Trove.new(),
		Equipped = {},
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

function WeaponService:_player_added(player)
	if player.Parent ~= Players then
		return
	end

	self.Equipped[player] = Fists
end

function WeaponService:GetEquipped(player)
	return self.Equipped[player]
end

function WeaponService:Equip(player, weapon_id)
	if player.Parent ~= Players then
		return false
	end

	local weapon_module = WeaponsFolder:FindFirstChild(weapon_id)
	if not weapon_module or not weapon_module:IsA("ModuleScript") then
		return false
	end

	local weapon = require(weapon_module)
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
