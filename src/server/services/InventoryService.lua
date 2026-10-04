-- Server-owned hotbar backed by the player's profile. Slot records live in
-- the profile data (PlayerDataService), keyed "1".."MaxSlots", each with a
-- unique Uid; the selected slot is session state and resets on join. Every
-- change is replicated to the owner as a dense, slot-ordered entry list. The
-- default weapon (Catalog.DefaultId) is implicit and never occupies a slot.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
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

-- Item ids and uids share the same bounded string check.
local function is_valid_id(value)
	return typeof(value) == "string"
		and value ~= ""
		and #value <= MAX_ITEM_ID_LENGTH
end

local function slot_key(slot)
	return tostring(slot)
end

local function weapon_id_of(record)
	local item = record and ItemCatalog.Get(record.ItemId)
	return item and item.WeaponId or DEFAULT_ID
end

-- Profile slots are keyed by string; RemoteEvents need a dense array, so
-- replication always uses this slot-ordered list of primitive-only entries.
local function build_entries(slots)
	local entries = {}

	for slot = 1, MAX_SLOTS do
		local record = slots[slot_key(slot)]
		if record ~= nil then
			table.insert(entries, {
				Slot = slot,
				Uid = record.Uid,
				ItemId = record.ItemId,
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
	Deps.check(deps, "InventoryService", { "players", "data", "remote", "budget", "telemetry" })

	local self = setmetatable({
		Trove = Trove.new(),
		Changed = Signal.new(),

		_players = deps.players,
		_data = deps.data,
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
	elseif action == Protocol.Inventory.SelectUid then
		self:SelectUid(player, value)
	end
end

-- A player without loaded data (kicked on a live server) gets no inventory
-- state, so every query answers as for a player who is not in game.
function InventoryService:OnPlayerAdded(session)
	if not self._data:GetData(session.Player) then
		return
	end

	session:Set(self, {
		SelectedSlot = nil,
	})

	self:_sync(session.Player)
end

function InventoryService:OnPlayerRemoving(session)
	session:Clear(self)
end

-- Returns (slots, selection state, session) for a present player.
function InventoryService:_get(player)
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil, nil, nil
	end

	local state = session:Get(self)
	local data = state and self._data:GetData(player)
	if not data then
		return nil, nil, nil
	end

	return data.Inventory.Slots, state, session
end

function InventoryService:_snapshot(player)
	local slots, state = self:_get(player)
	if not slots then
		return nil
	end

	-- Entries are freshly built tables of primitive values, so the payload
	-- is detached from the profile data.
	return {
		Entries = build_entries(slots),
		SelectedSlot = state.SelectedSlot or NO_SELECTION,
	}
end

function InventoryService:_replicate(player)
	local snapshot = self:_snapshot(player)
	if not snapshot then
		return false
	end

	self._remote:FireClient(player, Protocol.Inventory.Changed, snapshot.Entries, snapshot.SelectedSlot)

	return true
end

-- Changed is a gameplay signal and only fires for Ready sessions. While a
-- session is loading, components read the selection directly instead.
function InventoryService:_sync(player)
	local slots, state, session = self:_get(player)
	if not slots then
		return
	end

	if session.Phase == "Ready" then
		self.Changed:Fire(player, self:GetEquippedWeaponId(player), state.SelectedSlot or NO_SELECTION)
	end

	self:_replicate(player)
end

-- Re-announces after a slot write: a change to the selected slot can change
-- the equipped weapon, any other change only needs replicating.
function InventoryService:_after_write(player, state, slot)
	if state.SelectedSlot == slot then
		self:_sync(player)
	else
		self:_replicate(player)
	end
end

-- A detached view, so callers cannot bypass validation, replication or
-- Changed by mutating it.
function InventoryService:Get(player)
	return self:_snapshot(player)
end

function InventoryService:GetSelectedSlot(player)
	local _, state = self:_get(player)
	return state and state.SelectedSlot
end

-- A detached copy of the selected slot's record, or nil.
function InventoryService:GetSelected(player)
	local slots, state = self:_get(player)
	if not slots or not state.SelectedSlot then
		return nil
	end

	local record = slots[slot_key(state.SelectedSlot)]
	return record and Freeze.clone_deep(record)
end

function InventoryService:GetEquippedWeaponId(player)
	local slots, state = self:_get(player)
	if not slots or not state.SelectedSlot then
		return DEFAULT_ID
	end

	return weapon_id_of(slots[slot_key(state.SelectedSlot)])
end

function InventoryService:_find_empty_slot(slots)
	for slot = 1, MAX_SLOTS do
		if slots[slot_key(slot)] == nil then
			return slot
		end
	end
	return nil
end

-- Adds a new item to the given empty slot, or the first empty slot. Returns
-- the new uid, or nil when the item is unknown or there is no room.
function InventoryService:Grant(player, item_id, slot)
	if not is_valid_id(item_id) or ItemCatalog.Get(item_id) == nil then
		return nil
	end

	local slots, state = self:_get(player)
	if not slots then
		return nil
	end

	if slot == nil then
		slot = self:_find_empty_slot(slots)
		if slot == nil then
			return nil
		end
	elseif not is_valid_slot(slot) or slots[slot_key(slot)] ~= nil then
		return nil
	end

	local uid = HttpService:GenerateGUID(false)
	slots[slot_key(slot)] = {
		Uid = uid,
		ItemId = item_id,
		Data = {},
	}

	self:_after_write(player, state, slot)

	return uid
end

function InventoryService:_find_uid(slots, uid)
	for slot = 1, MAX_SLOTS do
		local record = slots[slot_key(slot)]
		if record and record.Uid == uid then
			return slot
		end
	end
	return nil
end

function InventoryService:RemoveUid(player, uid)
	if not is_valid_id(uid) then
		return false
	end

	local slots, state = self:_get(player)
	if not slots then
		return false
	end

	local slot = self:_find_uid(slots, uid)
	if not slot then
		return false
	end

	slots[slot_key(slot)] = nil
	self:_after_write(player, state, slot)

	return true
end

-- nil or NO_SELECTION selects nothing (the default weapon). Selecting the
-- selected slot toggles back to nothing. An empty slot can be selected; it
-- holds the default weapon.
function InventoryService:SelectSlot(player, slot)
	if slot == NO_SELECTION then
		slot = nil
	end

	if slot ~= nil and not is_valid_slot(slot) then
		return false
	end

	local slots, state = self:_get(player)
	if not slots then
		return false
	end

	if state.SelectedSlot == slot then
		slot = nil
	end

	state.SelectedSlot = slot
	self:_sync(player)

	return true
end

-- Selects the slot holding uid (toggling it off if it is already selected).
-- Unknown uids are ignored.
function InventoryService:SelectUid(player, uid)
	if not is_valid_id(uid) then
		return false
	end

	local slots = self:_get(player)
	if not slots then
		return false
	end

	local slot = self:_find_uid(slots, uid)
	if not slot then
		return false
	end

	return self:SelectSlot(player, slot)
end

function InventoryService:Destroy()
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return InventoryService
