--!strict
-- Equips each player's selected weapon and attaches its model to the current
-- character.
--
-- Models are cached per character: the first equip of a weapon clones and
-- binds its template, later swaps only reparent (the unequipped model goes to
-- nil, keeping its joints). Cached models live in the character trove and die
-- with the character.
--
-- Equip requests are coalesced: the first request in a quiet period applies
-- at once; requests inside the following Inventory.EquipCoalesceWindow only
-- record the latest id, which is applied when the window closes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local InventoryService = require(script.Parent.InventoryService)
local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)
local WeaponAttachment = require(script.Parent.WeaponAttachment)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession
type Trove = PlayerSession.Trove
type WeaponDefinition = Catalog.WeaponDefinition

-- A weapon model built for one character, with its wield parts by name.
type Entry = { Model: Instance, Wielded: { [string]: Instance } }

-- Per-session state. Character, CharacterTrove and Models (weapon id ->
-- Entry) belong to the current character; Current is the entry parented
-- into it.
type State = {
	Equipped: WeaponDefinition?,
	Character: Model?,
	CharacterTrove: Trove?,
	Models: { [string]: Entry },
	Current: Entry?,
	WindowOpen: boolean,
	Pending: WeaponDefinition?,
	CancelWindow: Scheduler.Cancel?,
	Destroy: () -> (),
}

export type WeaponServiceDeps = {
	players: PlayerService,
	inventory: InventoryService.InventoryService,
	-- The Weapon RemoteEvent (a FakeRemote in specs).
	remote: RemoteEvent,
	-- The template folder; nil when the place has none, in which case nothing
	-- can be equipped beyond the default.
	weapon_models: Instance?,
	scheduler: Scheduler.Scheduler,
}

local COALESCE_WINDOW = Config.Inventory.EquipCoalesceWindow

local WeaponService = {}
WeaponService.__index = WeaponService

type WeaponServiceFields = {
	Trove: Trove,
	-- Vendored GoodSignal is untyped. Fires (player: Player, weapon: WeaponDefinition).
	EquippedChanged: any,

	_players: PlayerService,
	_inventory: InventoryService.InventoryService,
	_remote: RemoteEvent,
	_weapon_models: Instance?,
	_scheduler: Scheduler.Scheduler,
	-- Weapon ids whose missing template was already reported.
	_warned_missing: { [string]: boolean },
}

export type WeaponService = typeof(setmetatable({} :: WeaponServiceFields, WeaponService))

function WeaponService.new(deps: WeaponServiceDeps): WeaponService
	Deps.check(deps, "WeaponService", { "players", "inventory", "remote", "scheduler" })

	local fields: WeaponServiceFields = {
		Trove = Trove.new(),
		EquippedChanged = Signal.new(),

		_players = deps.players,
		_inventory = deps.inventory,
		_remote = deps.remote,
		_weapon_models = deps.weapon_models,
		_scheduler = deps.scheduler,
		_warned_missing = {},
	}
	local self = setmetatable(fields, WeaponService)

	self.Trove:Add(self.EquippedChanged)

	self.Trove:Connect(self._inventory.Changed, function(player: Player, weapon_id: string)
		self:Equip(player, weapon_id)
	end)

	deps.players:Register(self, "WeaponService")

	return self
end

local function new_state(weapon: WeaponDefinition?): State
	local state: State
	state = {
		Equipped = weapon,
		Character = nil,
		CharacterTrove = nil,
		Models = {},
		Current = nil,
		WindowOpen = false,
		Pending = nil,
		CancelWindow = nil,
		Destroy = function()
			local cancel = state.CancelWindow
			state.CancelWindow = nil
			state.WindowOpen = false
			state.Pending = nil
			if cancel then
				cancel()
			end
		end,
	}
	return state
end

function WeaponService._state(self: WeaponService, player: Player): State?
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil
	end
	return session:Get(self) :: State?
end

function WeaponService.OnPlayerAdded(self: WeaponService, session: PlayerSession)
	local state = new_state(Catalog.Get(Catalog.DefaultId))
	session:Set(self, state)
	-- PlayerDataService and InventoryService are registered first, so the
	-- selection is already seeded.
	local weapon = Catalog.Get(self._inventory:GetEquippedWeaponId(session.Player))
	if weapon and weapon ~= state.Equipped and self:_has_template(session.Player, weapon) then
		self:_apply(session.Player, state, weapon)
	end
end

function WeaponService.OnCharacterAdded(self: WeaponService, session: PlayerSession, character: Model, trove: Trove)
	local state = session:Get(self) :: State?
	if not state then
		return
	end

	state.Character = character
	state.CharacterTrove = trove
	state.Models = {}
	state.Current = nil
	self:_attach(session.Player, state)
end

function WeaponService.OnCharacterRemoving(self: WeaponService, session: PlayerSession, character: Model)
	local state = session:Get(self) :: State?
	if not state or state.Character ~= character then
		return
	end

	-- The character trove is destroyed right after this hook, taking every
	-- cached model with it.
	state.Character = nil
	state.CharacterTrove = nil
	state.Models = {}
	state.Current = nil
end

function WeaponService.OnPlayerRemoving(self: WeaponService, session: PlayerSession)
	session:Clear(self)
end

function WeaponService._has_template(self: WeaponService, player: Player, weapon: WeaponDefinition): boolean
	local models = self._weapon_models
	if models and models:FindFirstChild(weapon.Model) then
		return true
	end

	if not self._warned_missing[weapon.Id] then
		self._warned_missing[weapon.Id] = true
		warn(("[WeaponService] Cannot equip %q (first requested by %s): model template %q is missing from %s"):format(
			weapon.Id,
			tostring(player.Name),
			tostring(weapon.Model),
			if models then models:GetFullName() else "ServerStorage (no weapon models folder)"
		))
	end
	return false
end

-- Builds the cached entry for a weapon on the current character, owned by
-- that character's trove.
function WeaponService._build(
	self: WeaponService,
	player: Player,
	character: Model,
	character_trove: Trove,
	weapon: WeaponDefinition
): Entry?
	local models = self._weapon_models
	local template = models and models:FindFirstChild(weapon.Model)
	if not template then
		self:_has_template(player, weapon)
		return nil
	end

	local clone = WeaponAttachment.Attach(template, weapon.Wield, character)
	if not clone then
		-- WeaponAttachment reports the model or binding failure with its source path.
		return nil
	end
	character_trove:Add(clone)

	local wielded: { [string]: Instance } = {}
	for wield_name in weapon.Wield do
		local part = clone:FindFirstChild(wield_name, true)
		if part then
			wielded[wield_name] = part
		end
	end

	return { Model = clone, Wielded = wielded }
end

-- Reparents a cached model. False when the model was destroyed elsewhere
-- (its Parent is locked), so the caller can rebuild it.
local function try_parent(model: Instance, parent: Instance?): boolean
	return (pcall(function()
		model.Parent = parent
	end))
end

function WeaponService._attach(self: WeaponService, player: Player, state: State)
	local character = state.Character
	local current = state.Current
	state.Current = nil
	if current and current.Model.Parent == character then
		try_parent(current.Model, nil)
	end

	local weapon = state.Equipped
	local character_trove = state.CharacterTrove
	if not character or not weapon or not character_trove then
		return
	end

	-- Without an attached weapon GetWielded returns nil, so CombatService
	-- also rejects attacks from unsupported rigs.
	local supported, reason = WeaponAttachment.IsSupportedRig(character)
	if not supported then
		warn(("[WeaponService] Not arming %s (%d): %s. Set Avatar Type to R6 in Game Settings > Avatar."):format(
			player.Name,
			player.UserId,
			tostring(reason)
		))
		return
	end

	local entry: Entry? = state.Models[weapon.Id]
	if entry and entry.Model.Parent ~= nil and entry.Model.Parent ~= character then
		-- Moved somewhere else by other code: stop trusting the cache.
		entry = nil
	end
	if entry and not try_parent(entry.Model, character) then
		entry = nil
	end
	if not entry then
		state.Models[weapon.Id] = nil
		entry = self:_build(player, character, character_trove, weapon)
		if not entry then
			return
		end
		state.Models[weapon.Id] = entry
	end

	state.Current = entry
end

function WeaponService._apply(self: WeaponService, player: Player, state: State, weapon: WeaponDefinition)
	if state.Equipped == weapon then
		return
	end

	state.Equipped = weapon
	self:_attach(player, state)

	self.EquippedChanged:Fire(player, weapon)
	self._remote:FireClient(player, Protocol.Weapon.Equipped, weapon.Id)
end

function WeaponService._open_window(self: WeaponService, player: Player, state: State)
	state.WindowOpen = true
	state.CancelWindow = self._scheduler.after(COALESCE_WINDOW, function()
		state.CancelWindow = nil
		state.WindowOpen = false

		local pending = state.Pending
		state.Pending = nil
		if pending == nil or self:_state(player) ~= state then
			return
		end

		if pending ~= state.Equipped then
			self:_apply(player, state, pending)
			self:_open_window(player, state)
		end
	end)
end

function WeaponService.GetEquipped(self: WeaponService, player: Player): WeaponDefinition?
	local state = self:_state(player)
	return state and state.Equipped
end

function WeaponService.GetWielded(self: WeaponService, player: Player, wield_name: string): Instance?
	local state = self:_state(player)
	local current = state and state.Current
	if not state or not current or current.Model.Parent ~= state.Character then
		return nil
	end

	local part = current.Wielded[wield_name]
	if part then
		return part
	end

	return current.Model:FindFirstChild(wield_name, true)
end

-- Returns true when the weapon is (or will be, at the end of the coalescing
-- window) equipped, false for an invalid request. `weapon_id` is untrusted.
function WeaponService.Equip(self: WeaponService, player: Player, weapon_id: unknown): boolean
	if type(weapon_id) ~= "string" then
		return false
	end

	local state = self:_state(player)
	if not state then
		return false
	end

	local weapon = Catalog.Get(weapon_id)
	if not weapon or not Catalog.IsEquippable(weapon) or weapon.Model == "" then
		return false
	end

	if not self:_has_template(player, weapon) then
		return false
	end

	if state.WindowOpen then
		state.Pending = weapon
		return true
	end

	if state.Equipped == weapon then
		return true
	end

	self:_apply(player, state, weapon)
	self:_open_window(player, state)

	return true
end

function WeaponService.Destroy(self: WeaponService)
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return WeaponService
