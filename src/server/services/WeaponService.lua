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
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local WeaponAttachment = require(script.Parent.WeaponAttachment)

local COALESCE_WINDOW = Config.Inventory.EquipCoalesceWindow

local WeaponService = {}
WeaponService.__index = WeaponService

-- deps.weapon_models is the template folder; it may be nil when the place
-- has none, in which case nothing can be equipped beyond the default.
function WeaponService.new(deps)
	Deps.check(deps, "WeaponService", { "players", "inventory", "remote", "scheduler" })

	local self = setmetatable({
		Trove = Trove.new(),
		EquippedChanged = Signal.new(),

		_players = deps.players,
		_inventory = deps.inventory,
		_remote = deps.remote,
		_weapon_models = deps.weapon_models,
		_scheduler = deps.scheduler,
		-- Weapon ids whose missing template was already reported.
		_warned_missing = {},
	}, WeaponService)

	self.Trove:Add(self.EquippedChanged)

	self.Trove:Connect(self._inventory.Changed, function(player, weapon_id)
		self:Equip(player, weapon_id)
	end)

	deps.players:Register(self, "WeaponService")

	return self
end

-- Per-session state. Character, CharacterTrove and Models (weapon id ->
-- { Model, Wielded }) belong to the current character; Current is the entry
-- parented into it.
local function new_state(weapon)
	local state = {
		Equipped = weapon,
		Character = nil,
		CharacterTrove = nil,
		Models = {},
		Current = nil,
		WindowOpen = false,
		Pending = nil,
		CancelWindow = nil,
	}

	function state.Destroy()
		local cancel = state.CancelWindow
		state.CancelWindow = nil
		state.WindowOpen = false
		state.Pending = nil
		if cancel then
			cancel()
		end
	end

	return state
end

function WeaponService:_state(player)
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil
	end
	return session:Get(self)
end

function WeaponService:OnPlayerAdded(session)
	local state = new_state(Catalog.Get(Catalog.DefaultId))
	session:Set(self, state)
	-- PlayerDataService and InventoryService are registered first, so the
	-- selection is already seeded.
	local weapon = Catalog.Get(self._inventory:GetEquippedWeaponId(session.Player))
	if weapon and weapon ~= state.Equipped and self:_has_template(session.Player, weapon) then
		self:_apply(session.Player, state, weapon)
	end
end

function WeaponService:OnCharacterAdded(session, character, trove)
	local state = session:Get(self)
	if not state then
		return
	end

	state.Character = character
	state.CharacterTrove = trove
	state.Models = {}
	state.Current = nil
	self:_attach(session.Player, state)
end

function WeaponService:OnCharacterRemoving(session, character)
	local state = session:Get(self)
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

function WeaponService:OnPlayerRemoving(session)
	session:Clear(self)
end

function WeaponService:_has_template(player, weapon)
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

-- Builds the cached entry for a weapon on the current character.
function WeaponService:_build(player, state, weapon)
	local models = self._weapon_models
	local template = models and models:FindFirstChild(weapon.Model)
	if not template then
		self:_has_template(player, weapon)
		return nil
	end

	local clone = WeaponAttachment.Attach(template, weapon.Wield, state.Character)
	if not clone then
		-- WeaponAttachment reports the model or binding failure with its source path.
		return nil
	end
	state.CharacterTrove:Add(clone)

	local wielded = {}
	for wield_name in pairs(weapon.Wield or {}) do
		local part = clone:FindFirstChild(wield_name, true)
		if part then
			wielded[wield_name] = part
		end
	end

	return { Model = clone, Wielded = wielded }
end

-- Reparents a cached model. False when the model was destroyed elsewhere
-- (its Parent is locked), so the caller can rebuild it.
local function try_parent(model, parent)
	return (pcall(function()
		model.Parent = parent
	end))
end

function WeaponService:_attach(player, state)
	local character = state.Character
	local current = state.Current
	state.Current = nil
	if current and current.Model.Parent == character then
		try_parent(current.Model, nil)
	end

	local weapon = state.Equipped
	if not character or not weapon or not state.CharacterTrove then
		return
	end

	-- Without an attached weapon GetWielded returns nil, so CombatService
	-- also rejects attacks from unsupported rigs.
	local supported, reason = WeaponAttachment.IsSupportedRig(character)
	if not supported then
		warn(("[WeaponService] Not arming %s (%d): %s. Set Avatar Type to R6 in Game Settings > Avatar."):format(
			player.Name,
			player.UserId,
			reason
		))
		return
	end

	local entry = state.Models[weapon.Id]
	if entry and entry.Model.Parent ~= nil and entry.Model.Parent ~= character then
		-- Moved somewhere else by other code: stop trusting the cache.
		entry = nil
	end
	if entry and not try_parent(entry.Model, character) then
		entry = nil
	end
	if not entry then
		state.Models[weapon.Id] = nil
		entry = self:_build(player, state, weapon)
		if not entry then
			return
		end
		state.Models[weapon.Id] = entry
	end

	state.Current = entry
end

function WeaponService:_apply(player, state, weapon)
	if state.Equipped == weapon then
		return
	end

	state.Equipped = weapon
	self:_attach(player, state)

	self.EquippedChanged:Fire(player, weapon)
	self._remote:FireClient(player, Protocol.Weapon.Equipped, weapon.Id)
end

function WeaponService:_open_window(player, state)
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

function WeaponService:GetEquipped(player)
	local state = self:_state(player)
	return state and state.Equipped
end

function WeaponService:GetWielded(player, wield_name)
	local state = self:_state(player)
	local current = state and state.Current
	if not current or current.Model.Parent ~= state.Character then
		return nil
	end

	local part = current.Wielded[wield_name]
	if part then
		return part
	end

	return current.Model:FindFirstChild(wield_name, true)
end

-- Returns true when the weapon is (or will be, at the end of the coalescing
-- window) equipped, false for an invalid request.
function WeaponService:Equip(player, weapon_id)
	if typeof(weapon_id) ~= "string" then
		return false
	end

	local state = self:_state(player)
	if not state then
		return false
	end

	local weapon = Catalog.Get(weapon_id)
	if not Catalog.IsEquippable(weapon) or typeof(weapon.Model) ~= "string" or weapon.Model == "" then
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

function WeaponService:Destroy()
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return WeaponService
