local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local InventoryRemote = ReplicatedStorage.remotes.Inventory
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local FISTS_ID = "Fists"
local MAX_SLOTS = 9
-- Replicated as the selected slot when nothing is selected (Fists).
local NO_SELECTION = 0
local MAX_ITEM_ID_LENGTH = 64
local REMOTE_MIN_INTERVAL = 0.08
local TEMPORARY_SLOTS = {
	[2] = "Katana",
}

local function is_valid_slot(slot)
	return typeof(slot) == "number"
		and math.isfinite(slot)
		and slot % 1 == 0
		and slot >= 1
		and slot <= MAX_SLOTS
end

local function is_valid_item_id(weapon_id)
	return typeof(weapon_id) == "string"
		and weapon_id ~= ""
		and #weapon_id <= MAX_ITEM_ID_LENGTH
end

-- Slots is stored sparsely by slot index. RemoteEvents drop or mangle sparse
-- arrays, so replication always uses this dense, slot-ordered entry list.
local function build_entries(slots)
	local entries = {}

	for slot = 1, MAX_SLOTS do
		local weapon_id = slots[slot]
		if weapon_id ~= nil then
			table.insert(entries, {
				Slot = slot,
				WeaponId = weapon_id,
			})
		end
	end

	return entries
end

local InventoryService = {}
InventoryService.__index = InventoryService
InventoryService.MAX_SLOTS = MAX_SLOTS
InventoryService.NO_SELECTION = NO_SELECTION

function InventoryService.new(player_service)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		Inventories = {},
		RemoteAt = {},

		Changed = Signal.new(),
	}, InventoryService)

	self.Trove:Add(self.Changed)
	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function InventoryService:_start()
	self.Trove:Connect(
		InventoryRemote.OnServerEvent,
		function(player, action, value)
			if action ~= Protocol.Inventory.SelectSlot
				and action ~= Protocol.Inventory.SelectItem then
				return
			end

			-- Ignore players without an inventory so RemoteAt cannot outlive
			-- PlayerRemoving for late or out-of-session requests.
			if not self:_get(player) or not self:_allow_remote(player) then
				return
			end

			if action == Protocol.Inventory.SelectSlot then
				self:SelectSlot(player, value)
			else
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

function InventoryService:_allow_remote(player)
	local now = os.clock()
	local last_at = self.RemoteAt[player]

	if last_at and now - last_at < REMOTE_MIN_INTERVAL then
		return false
	end

	self.RemoteAt[player] = now
	return true
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
	self.RemoteAt[player] = nil
end

function InventoryService:_get(player)
	return self.Inventories[player]
end

function InventoryService:_get_replication_snapshot(player)
	local inventory = self:_get(player)
	if not inventory then
		return nil
	end

	-- Entries are freshly built tables of primitive values, so the payload
	-- is detached from server-owned inventory state.
	return {
		Entries = build_entries(inventory.Slots),
		SelectedSlot = inventory.SelectedSlot or NO_SELECTION,
	}
end

function InventoryService:_replicate(player)
	local snapshot = self:_get_replication_snapshot(player)
	if not snapshot then
		return false
	end

	InventoryRemote:FireClient(
		player,
		Protocol.Inventory.Changed,
		snapshot.Entries,
		snapshot.SelectedSlot
	)

	return true
end

function InventoryService:_sync(player)
	local inventory = self:_get(player)
	if not inventory then
		return
	end

	local weapon_id = self:GetSelectedId(player)

	self.Changed:Fire(player, weapon_id, inventory.SelectedSlot)
	self:_replicate(player)
end

-- Return a detached view so callers cannot bypass inventory validation,
-- replication, or Changed notifications by mutating server-owned state.
function InventoryService:Get(player)
	return self:_get_replication_snapshot(player)
end

function InventoryService:GetSlot(player, slot)
	if not is_valid_slot(slot) then
		return nil
	end

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
	if not is_valid_slot(slot) then
		return false
	end

	if weapon_id == FISTS_ID then
		weapon_id = nil
	end

	if weapon_id ~= nil then
		if not is_valid_item_id(weapon_id) then
			return false
		end

		if not Catalog.IsMelee(Catalog.Get(weapon_id)) then
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
		self:_replicate(player)
	end

	return true
end

function InventoryService:SelectSlot(player, slot)
	if slot ~= nil and not is_valid_slot(slot) then
		return false
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
	if not is_valid_item_id(weapon_id) then
		return false
	end

	if weapon_id == FISTS_ID then
		return self:SelectSlot(player, nil)
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	for slot = 1, MAX_SLOTS do
		if inventory.Slots[slot] == weapon_id then
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

	for slot = 1, MAX_SLOTS do
		if inventory.Slots[slot] == nil then
			return slot
		end
	end

	return nil
end

function InventoryService:Remove(player, weapon_id)
	-- A nil ID would otherwise match the first empty slot.
	if not is_valid_item_id(weapon_id) then
		return false
	end

	local inventory = self:_get(player)
	if not inventory then
		return false
	end

	for slot = 1, MAX_SLOTS do
		if inventory.Slots[slot] == weapon_id then
			inventory.Slots[slot] = nil

			if inventory.SelectedSlot == slot then
				self:_sync(player)
			else
				self:_replicate(player)
			end

			return true
		end
	end

	return false
end

function InventoryService:Destroy()
	table.clear(self.Inventories)
	table.clear(self.RemoteAt)
	self.Trove:Destroy()
end

return InventoryService
