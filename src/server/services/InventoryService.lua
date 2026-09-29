local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local InventoryRemote = ReplicatedStorage.remotes.Inventory
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local FISTS_ID = "Fists"
local TEMPORARY_SLOTS = {
	[2] = "Katana",
}

local InventoryService = {}
InventoryService.__index = InventoryService

function InventoryService.new(player_service)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		Inventories = {},

		Changed = Signal.new(),
	}, InventoryService)

	self.Trove:Add(self.Changed)
	self:_start()

	return self
end

function InventoryService:_start()
	self.Trove:Connect(
		InventoryRemote.OnServerEvent,
		function(player, action, value)
			if action == Protocol.Inventory.SelectSlot then
				self:SelectSlot(player, value)
			elseif action == Protocol.Inventory.SelectItem then
				self:SelectItem(player, value)
			end
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

function InventoryService:_player_added(player)
	if self.Inventories[player] then
		return
	end

	local slots = {}

	for slot, weapon_id in pairs(TEMPORARY_SLOTS) do
		slots[slot] = weapon_id
	end

	self.Inventories[player] = {
		Slots = slots,
		SelectedSlot = nil,
	}

	self:_sync(player)
end

function InventoryService:_player_removing(player)
	self.Inventories[player] = nil
end

function InventoryService:_get(player)
	return self.Inventories[player]
end

function InventoryService:_sync(player)
	local inventory = self:_get(player)
	if not inventory then
		return
	end

	local weapon_id = self:GetSelectedId(player)

	self.Changed:Fire(player, weapon_id, inventory.SelectedSlot)

	InventoryRemote:FireClient(
		player,
		Protocol.Inventory.Changed,
		inventory.Slots,
		inventory.SelectedSlot
	)
end

function InventoryService:Get(player)
	return self:_get(player)
end

function InventoryService:GetSlot(player, slot)
	local inventory = self:_get(player)
	if not inventory then
		return nil
	end

	return inventory.Slots[slot]
end

function InventoryService:GetSelectedSlot(player)
	local inventory = self:_get(player)
	return inventory and inventory.SelectedSlot
end

function InventoryService:GetSelectedId(player)
	local inventory = self:_get(player)

	if not inventory or not inventory.SelectedSlot then
		return FISTS_ID
	end

	return inventory.Slots[inventory.SelectedSlot] or FISTS_ID
end

function InventoryService:Has(player, weapon_id)
	if weapon_id == FISTS_ID then
		return true
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	for _, item_id in pairs(inventory.Slots) do
		if item_id == weapon_id then
			return true
		end
	end

	return false
end

function InventoryService:SetSlot(player, slot, weapon_id)
	if typeof(slot) ~= "number" or slot < 1 or slot % 1 ~= 0 then
		return false
	end

	if weapon_id == FISTS_ID then
		weapon_id = nil
	end

	if weapon_id ~= nil then
		if typeof(weapon_id) ~= "string" then
			return false
		end

		local weapon_module = WeaponsFolder:FindFirstChild(weapon_id)
		if not weapon_module or not weapon_module:IsA("ModuleScript") then
			return false
		end

		local weapon = require(weapon_module)
		if weapon.Type ~= "Melee" then
			return false
		end
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	inventory.Slots[slot] = weapon_id

	if inventory.SelectedSlot == slot then
		self:_sync(player)
	else
		InventoryRemote:FireClient(
			player,
			Protocol.Inventory.Changed,
			inventory.Slots,
			inventory.SelectedSlot
		)
	end

	return true
end

function InventoryService:SelectSlot(player, slot)
	if slot ~= nil then
		if typeof(slot) ~= "number" or slot < 1 or slot % 1 ~= 0 then
			return false
		end
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	if inventory.SelectedSlot == slot then
		slot = nil
	end

	inventory.SelectedSlot = slot
	self:_sync(player)

	return true
end

function InventoryService:SelectItem(player, weapon_id)
	if typeof(weapon_id) ~= "string" then
		return false
	end

	if weapon_id == FISTS_ID then
		return self:SelectSlot(player, nil)
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	for slot, item_id in pairs(inventory.Slots) do
		if item_id == weapon_id then
			return self:SelectSlot(player, slot)
		end
	end

	return false
end

function InventoryService:Give(player, weapon_id, slot)
	if slot == nil then
		slot = self:_find_empty_slot(player)
	end

	return slot ~= nil and self:SetSlot(player, slot, weapon_id)
end

function InventoryService:_find_empty_slot(player)
	local inventory = self:_get(player)
	if not inventory then
		return nil
	end

	local slot = 1

	while inventory.Slots[slot] ~= nil do
		slot += 1
	end

	return slot
end

function InventoryService:Remove(player, weapon_id)
	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	for slot, item_id in pairs(inventory.Slots) do
		if item_id == weapon_id then
			inventory.Slots[slot] = nil

			if inventory.SelectedSlot == slot then
				self:_sync(player)
			else
				InventoryRemote:FireClient(
					player,
					Protocol.Inventory.Changed,
					inventory.Slots,
					inventory.SelectedSlot
				)
			end

			return true
		end
	end

	return false
end

function InventoryService:Destroy()
	table.clear(self.Inventories)
	self.Trove:Destroy()
end

return InventoryService
