--!strict
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
local Schema = require(ReplicatedStorage.shared.data.Schema)

local RemoteBudget = require(script.Parent.Parent.network.RemoteBudget)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)
local Telemetry = require(script.Parent.Telemetry)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession
type SlotRecord = Schema.SlotRecord
type Slots = { [string]: SlotRecord }

-- One replicated slot: primitives only.
export type Entry = { Slot: number, Uid: string, ItemId: string }

export type Snapshot = { Entries: { Entry }, SelectedSlot: number }

type State = { SelectedSlot: number? }

-- The profile slots, selection state and session of a present player.
type Present = { Slots: Slots, State: State, Session: PlayerSession }

export type InventoryServiceDeps = {
	players: PlayerService,
	data: PlayerDataService.PlayerDataService,
	-- The Inventory RemoteEvent (a FakeRemote in specs).
	remote: RemoteEvent,
	budget: RemoteBudget.RemoteBudget,
	telemetry: Telemetry.Telemetry,
}

local DEFAULT_ID = Catalog.DefaultId
local MAX_SLOTS = Config.Inventory.MaxSlots
local MAX_ITEM_ID_LENGTH = Config.Inventory.MaxItemIdLength
-- Replicated as the selected slot when nothing is selected (default weapon).
-- SelectSlot also accepts it to mean "select nothing".
local NO_SELECTION = 0

local function is_valid_slot(slot: unknown): boolean
	if type(slot) ~= "number" then
		return false
	end
	return math.isfinite(slot) and slot % 1 == 0 and slot >= 1 and slot <= MAX_SLOTS
end

-- Item ids and uids share the same bounded string check.
local function is_valid_id(value: unknown): boolean
	return type(value) == "string" and value ~= "" and #value <= MAX_ITEM_ID_LENGTH
end

local function slot_key(slot: number): string
	return tostring(slot)
end

local function weapon_id_of(record: SlotRecord?): string
	local item = record and ItemCatalog.Get(record.ItemId)
	return item and item.WeaponId or DEFAULT_ID
end

-- Profile slots are keyed by string; RemoteEvents need a dense array, so
-- replication always uses this slot-ordered list of primitive-only entries.
local function build_entries(slots: Slots): { Entry }
	local entries: { Entry } = {}

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

local function find_empty_slot(slots: Slots): number?
	for slot = 1, MAX_SLOTS do
		if slots[slot_key(slot)] == nil then
			return slot
		end
	end
	return nil
end

local function find_uid(slots: Slots, uid: string): number?
	for slot = 1, MAX_SLOTS do
		local record = slots[slot_key(slot)]
		if record and record.Uid == uid then
			return slot
		end
	end
	return nil
end

local InventoryService = {}
InventoryService.__index = InventoryService
InventoryService.MAX_SLOTS = MAX_SLOTS
InventoryService.NO_SELECTION = NO_SELECTION

type InventoryServiceFields = {
	Trove: PlayerSession.Trove,
	-- Vendored GoodSignal is untyped. Fires (player: Player,
	-- equipped_weapon_id: string, selected_slot: number) for Ready sessions.
	Changed: any,

	_players: PlayerService,
	_data: PlayerDataService.PlayerDataService,
	_remote: RemoteEvent,
	_budget: RemoteBudget.RemoteBudget,
	_telemetry: Telemetry.Telemetry,
}

export type InventoryService = typeof(setmetatable({} :: InventoryServiceFields, InventoryService))

function InventoryService.new(deps: InventoryServiceDeps): InventoryService
	Deps.check(deps, "InventoryService", { "players", "data", "remote", "budget", "telemetry" })

	local fields: InventoryServiceFields = {
		Trove = Trove.new(),
		Changed = Signal.new(),

		_players = deps.players,
		_data = deps.data,
		_remote = deps.remote,
		_budget = deps.budget,
		_telemetry = deps.telemetry,
	}
	local self = setmetatable(fields, InventoryService)

	self.Trove:Add(self.Changed)

	self.Trove:Connect(self._remote.OnServerEvent, function(player: Player, action: unknown, value: unknown)
		self:_on_remote(player, action, value)
	end)

	deps.players:Register(self, "InventoryService")

	return self
end

function InventoryService._on_remote(self: InventoryService, player: Player, action: unknown, value: unknown)
	if type(action) ~= "string" then
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
function InventoryService.OnPlayerAdded(self: InventoryService, session: PlayerSession)
	if not self._data:GetData(session.Player) then
		return
	end

	local state: State = { SelectedSlot = nil }
	session:Set(self, state)

	self:_sync(session.Player)
end

function InventoryService.OnPlayerRemoving(self: InventoryService, session: PlayerSession)
	session:Clear(self)
end

function InventoryService._get(self: InventoryService, player: Player): Present?
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil
	end

	local state = session:Get(self) :: State?
	local data = state and self._data:GetData(player)
	if not state or not data then
		return nil
	end

	return { Slots = data.Inventory.Slots, State = state, Session = session }
end

function InventoryService._snapshot(self: InventoryService, player: Player): Snapshot?
	local present = self:_get(player)
	if not present then
		return nil
	end

	-- Entries are freshly built tables of primitive values, so the payload
	-- is detached from the profile data.
	return {
		Entries = build_entries(present.Slots),
		SelectedSlot = present.State.SelectedSlot or NO_SELECTION,
	}
end

function InventoryService._replicate(self: InventoryService, player: Player): boolean
	local snapshot = self:_snapshot(player)
	if not snapshot then
		return false
	end

	self._remote:FireClient(player, Protocol.Inventory.Changed, snapshot.Entries, snapshot.SelectedSlot)

	return true
end

-- Changed is a gameplay signal and only fires for Ready sessions. While a
-- session is loading, components read the selection directly instead.
function InventoryService._sync(self: InventoryService, player: Player)
	local present = self:_get(player)
	if not present then
		return
	end

	if present.Session.Phase == "Ready" then
		self.Changed:Fire(player, self:GetEquippedWeaponId(player), present.State.SelectedSlot or NO_SELECTION)
	end

	self:_replicate(player)
end

-- Re-announces after a slot write: a change to the selected slot can change
-- the equipped weapon, any other change only needs replicating.
function InventoryService._after_write(self: InventoryService, player: Player, state: State, slot: number)
	if state.SelectedSlot == slot then
		self:_sync(player)
	else
		self:_replicate(player)
	end
end

-- A detached view, so callers cannot bypass validation, replication or
-- Changed by mutating it.
function InventoryService.Get(self: InventoryService, player: Player): Snapshot?
	return self:_snapshot(player)
end

function InventoryService.GetSelectedSlot(self: InventoryService, player: Player): number?
	local present = self:_get(player)
	return present and present.State.SelectedSlot
end

-- A detached copy of the selected slot's record, or nil.
function InventoryService.GetSelected(self: InventoryService, player: Player): SlotRecord?
	local present = self:_get(player)
	local selected = present and present.State.SelectedSlot
	if not present or not selected then
		return nil
	end

	local record = present.Slots[slot_key(selected)]
	return record and Freeze.clone_deep(record)
end

function InventoryService.GetEquippedWeaponId(self: InventoryService, player: Player): string
	local present = self:_get(player)
	local selected = present and present.State.SelectedSlot
	if not present or not selected then
		return DEFAULT_ID
	end

	return weapon_id_of(present.Slots[slot_key(selected)])
end

-- Adds a new item to the given empty slot, or the first empty slot. Returns
-- the new uid, or nil when the item is unknown or there is no room. Both
-- arguments are checked, so callers may pass unvalidated values.
function InventoryService.Grant(self: InventoryService, player: Player, item_id: unknown, slot: unknown): string?
	if not is_valid_id(item_id) or ItemCatalog.Get(item_id) == nil then
		return nil
	end

	local present = self:_get(player)
	if not present then
		return nil
	end
	local slots = present.Slots

	local target: number
	if slot == nil then
		local empty = find_empty_slot(slots)
		if empty == nil then
			return nil
		end
		target = empty
	elseif is_valid_slot(slot) and slots[slot_key(slot :: number)] == nil then
		target = slot :: number
	else
		return nil
	end

	local uid = HttpService:GenerateGUID(false)
	slots[slot_key(target)] = {
		Uid = uid,
		ItemId = item_id :: string,
		Data = {},
	}

	self:_after_write(player, present.State, target)

	return uid
end

function InventoryService.RemoveUid(self: InventoryService, player: Player, uid: unknown): boolean
	if not is_valid_id(uid) then
		return false
	end

	local present = self:_get(player)
	if not present then
		return false
	end

	local slot = find_uid(present.Slots, uid :: string)
	if not slot then
		return false
	end

	present.Slots[slot_key(slot)] = nil
	self:_after_write(player, present.State, slot)

	return true
end

-- nil or NO_SELECTION selects nothing (the default weapon). Selecting the
-- selected slot toggles back to nothing. An empty slot can be selected; it
-- holds the default weapon. `slot` may come straight from a remote payload.
function InventoryService.SelectSlot(self: InventoryService, player: Player, slot: unknown): boolean
	local selected: number? = nil
	if slot ~= nil and slot ~= NO_SELECTION then
		if not is_valid_slot(slot) then
			return false
		end
		selected = slot :: number
	end

	local present = self:_get(player)
	if not present then
		return false
	end

	local state = present.State
	if state.SelectedSlot == selected then
		selected = nil
	end

	state.SelectedSlot = selected
	self:_sync(player)

	return true
end

-- Selects the slot holding uid (toggling it off if it is already selected).
-- Unknown uids are ignored. `uid` may come straight from a remote payload.
function InventoryService.SelectUid(self: InventoryService, player: Player, uid: unknown): boolean
	if not is_valid_id(uid) then
		return false
	end

	local present = self:_get(player)
	if not present then
		return false
	end

	local slot = find_uid(present.Slots, uid :: string)
	if not slot then
		return false
	end

	return self:SelectSlot(player, slot)
end

function InventoryService.Destroy(self: InventoryService)
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return InventoryService
