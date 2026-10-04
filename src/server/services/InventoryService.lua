-- Server-owned hotbar. Each session's inventory is PlayerService component
-- state: seeded from the Starter loadout when the player joins, replicated to
-- the owner on every change, and gone when the session ends. The default
-- weapon (Catalog.DefaultId) is implicit and never occupies a slot.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local DEFAULT_ID = Catalog.DefaultId
local MAX_SLOTS = Config.Inventory.MaxSlots
local MAX_ITEM_ID_LENGTH = Config.Inventory.MaxItemIdLength
-- Replicated as the selected slot when nothing is selected (default weapon).
-- SelectSlot also accepts it to mean "select nothing".
local NO_SELECTION = 0

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

function InventoryService.new(deps)
	Deps.check(deps, "InventoryService", { "players", "remote", "budget", "telemetry" })

	local self = setmetatable({
		Trove = Trove.new(),
		Changed = Signal.new(),

		_players = deps.players,
		_remote = deps.remote,
		_budget = deps.budget,
		_telemetry = deps.telemetry,
	}, InventoryService)

	self.Trove:Add(self.Changed)

	self.Trove:Connect(self._remote.OnServerEvent, function(player, action, value)
		self:_on_remote(player, action, value)
	end)

	deps.players:Register(self, "InventoryService")

	return self
end

function InventoryService:_on_remote(player, action, value)
	if typeof(action) ~= "string" then
		self._telemetry:Count(player, "Network", "BadPayload", "Inventory")
		return
	end

	if not self._budget:Take(player, "Inventory." .. action) then
		return
	end

	if not self._players:GetReady(player) then
		return
	end

	if action == Protocol.Inventory.SelectSlot then
		self:SelectSlot(player, value)
	elseif action == Protocol.Inventory.SelectItem then
		self:SelectItem(player, value)
	end
end

function InventoryService:OnPlayerAdded(session)
	local slots = {}
	for slot, weapon_id in pairs(Catalog.Loadout("Starter")) do
		slots[slot] = weapon_id
	end

	session:Set(self, {
		Slots = slots,
		SelectedSlot = nil,
	})

	self:_sync(session.Player)
end

function InventoryService:OnPlayerRemoving(session)
	session:Clear(self)
end

function InventoryService:_get(player)
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil, nil
	end
	return session:Get(self), session
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

	self._remote:FireClient(
		player,
		Protocol.Inventory.Changed,
		snapshot.Entries,
		snapshot.SelectedSlot
	)

	return true
end

-- Changed is a gameplay signal and only fires for Ready sessions. While a
-- session is loading, components read the selection directly instead.
function InventoryService:_sync(player)
	local inventory, session = self:_get(player)
	if not inventory then
		return
	end

	if session.Phase == "Ready" then
		self.Changed:Fire(player, self:GetSelectedId(player), inventory.SelectedSlot)
	end

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
		return DEFAULT_ID
	end

	return inventory.Slots[inventory.SelectedSlot] or DEFAULT_ID
end

function InventoryService:Has(player, weapon_id)
	if weapon_id == DEFAULT_ID then
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

	if weapon_id == DEFAULT_ID then
		weapon_id = nil
	end

	if weapon_id ~= nil then
		if not is_valid_item_id(weapon_id) then
			return false
		end

		if not Catalog.IsEquippable(Catalog.Get(weapon_id)) then
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

-- nil or NO_SELECTION selects nothing (the default weapon). Selecting the
-- selected slot toggles back to nothing.
function InventoryService:SelectSlot(player, slot)
	if slot == NO_SELECTION then
		slot = nil
	end

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

	if weapon_id == DEFAULT_ID then
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
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return InventoryService
