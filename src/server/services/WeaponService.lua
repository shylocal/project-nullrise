local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local WeaponModels = ReplicatedStorage.weapon_models
local WeaponRemote = ReplicatedStorage.remotes.Weapon
local Fists = Catalog.Get("Fists")
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local WeaponAttachment = require(script.Parent.WeaponAttachment)

local WeaponService = {}
WeaponService.__index = WeaponService

function WeaponService.new(player_service, inventory_service)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		InventoryService = inventory_service,

		Equipped = {},
		CharacterTroves = {},
		PlayerTroves = {},
		Wielded = {},

		EquippedChanged = Signal.new(),
	}, WeaponService)

	self.Trove:Add(self.EquippedChanged)
	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function WeaponService:_start()
	self.Trove:Connect(
		self.InventoryService.Changed,
		function(player, weapon_id)
			self:Equip(player, weapon_id)
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerAdded,
		function(player)
			self:_player_added(player)
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerRemoving,
		function(player)
			self:_player_removing(player)
		end
	)

	for _, player in self.PlayerService:GetPlayers() do
		self:_player_added(player)
	end
end

function WeaponService:_player_added(player)
	if self.Equipped[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	local player_trove = Trove.new()
	self.PlayerTroves[player] = player_trove

	self.Equipped[player] = Fists

	player_trove:Connect(
		session.CharacterAdded,
		function(character)
			self:_character_added(player, character)
		end
	)

	player_trove:Connect(
		session.CharacterRemoving,
		function(character)
			self:_character_removing(player, character)
		end
	)

	if session.Character then
		self:_character_added(player, session.Character)
	end

	self:Equip(player, self.InventoryService:GetSelectedId(player))
end

function WeaponService:_character_added(player, character)
	self:_clear_character(player)

	local weapon = self.Equipped[player]
	if not weapon then
		return
	end

	local character_trove = Trove.new()

	self.CharacterTroves[player] = character_trove
	self.Wielded[player] = {}

	self:_attach_weapon(player, character, weapon, character_trove)
end

function WeaponService:_character_removing(player, character)
	local session = self.PlayerService:Get(player)
	if session and session.Character == character then
		self:_clear_character(player)
	end
end

function WeaponService:_clear_character(player)
	local character_trove = self.CharacterTroves[player]

	if character_trove then
		character_trove:Destroy()
		self.CharacterTroves[player] = nil
	end

	self.Wielded[player] = nil
end

function WeaponService:_attach_weapon(player, character, weapon, character_trove)
	local model = WeaponModels:FindFirstChild(weapon.Model)
	if not model then
		return
	end

	local clone = WeaponAttachment.Attach(model, weapon.Wield, character)
	if not clone then
		return
	end

	character_trove:Add(clone)
	self.Wielded[player].Model = clone

	for wield_name in pairs(weapon.Wield or {}) do
		local wielded = clone:FindFirstChild(wield_name, true)

		if wielded then
			self.Wielded[player][wield_name] = wielded
		end
	end
end

function WeaponService:GetEquipped(player)
	return self.Equipped[player]
end

function WeaponService:GetWielded(player, wield_name)
	local wielded = self.Wielded[player]
	if not wielded then
		return nil
	end

	local part = wielded[wield_name]
	if part then
		return part
	end

	local model = wielded.Model
	return model and model:FindFirstChild(wield_name, true)
end

function WeaponService:Equip(player, weapon_id)
	if typeof(weapon_id) ~= "string" then
		return false
	end

	if not self.PlayerService:Get(player) then
		return false
	end

	local weapon = Catalog.Get(weapon_id)
	if not weapon or typeof(weapon.Model) ~= "string" or weapon.Model == "" then
		return false
	end

	if not WeaponModels:FindFirstChild(weapon.Model) then
		return false
	end

	local current = self.Equipped[player]
	if current == weapon then
		return true
	end

	self.Equipped[player] = weapon

	local session = self.PlayerService:Get(player)
	if session and session.Character then
		self:_character_added(player, session.Character)
	end

	self.EquippedChanged:Fire(player, weapon)
	WeaponRemote:FireClient(player, Protocol.Weapon.Equipped, weapon_id)

	return true
end

function WeaponService:_player_removing(player)
	self:_clear_character(player)

	local player_trove = self.PlayerTroves[player]
	if player_trove then
		player_trove:Destroy()
		self.PlayerTroves[player] = nil
	end

	self.Equipped[player] = nil
end

function WeaponService:Destroy()
	for player in pairs(self.PlayerTroves) do
		self:_player_removing(player)
	end

	for player in pairs(self.CharacterTroves) do
		self:_clear_character(player)
	end

	table.clear(self.PlayerTroves)
	table.clear(self.CharacterTroves)
	table.clear(self.Wielded)
	table.clear(self.Equipped)

	self.Trove:Destroy()
end

return WeaponService
