-- Equips each player's selected weapon and attaches its model to the current
-- character. Per-session state (equipped definition, attached model, wielded
-- parts) is PlayerService component state; the attached model lives in the
-- character's trove and is replaced on every equip change.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local WeaponAttachment = require(script.Parent.WeaponAttachment)

local WeaponService = {}
WeaponService.__index = WeaponService

-- deps.weapon_models is the template folder; it may be nil when the place
-- has none, in which case nothing can be equipped beyond the default.
function WeaponService.new(deps)
	Deps.check(deps, "WeaponService", { "players", "inventory", "remote" })

	local self = setmetatable({
		Trove = Trove.new(),
		EquippedChanged = Signal.new(),

		_players = deps.players,
		_inventory = deps.inventory,
		_remote = deps.remote,
		_weapon_models = deps.weapon_models,
	}, WeaponService)

	self.Trove:Add(self.EquippedChanged)

	self.Trove:Connect(self._inventory.Changed, function(player, weapon_id)
		self:Equip(player, weapon_id)
	end)

	deps.players:Register(self, "WeaponService")

	return self
end

local function new_state(weapon)
	return {
		Equipped = weapon,
		Character = nil,
		CharacterTrove = nil,
		AttachTrove = nil,
		Wielded = nil,
	}
end

function WeaponService:_state(player)
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil
	end
	return session:Get(self)
end

function WeaponService:OnPlayerAdded(session)
	session:Set(self, new_state(Catalog.Get(Catalog.DefaultId)))
	-- InventoryService is registered first, so its selection is seeded.
	self:Equip(session.Player, self._inventory:GetSelectedId(session.Player))
end

function WeaponService:OnCharacterAdded(session, character, trove)
	local state = session:Get(self)
	if not state then
		return
	end

	state.Character = character
	state.CharacterTrove = trove
	self:_attach(session.Player, state)
end

function WeaponService:OnCharacterRemoving(session, character)
	local state = session:Get(self)
	if not state or state.Character ~= character then
		return
	end

	-- The character trove is destroyed right after this hook, taking the
	-- attached model with it.
	state.Character = nil
	state.CharacterTrove = nil
	state.AttachTrove = nil
	state.Wielded = nil
end

function WeaponService:OnPlayerRemoving(session)
	session:Clear(self)
end

function WeaponService:_detach(state)
	local attach_trove = state.AttachTrove
	state.AttachTrove = nil
	state.Wielded = nil

	if attach_trove and state.CharacterTrove then
		state.CharacterTrove:Remove(attach_trove)
	elseif attach_trove then
		attach_trove:Destroy()
	end
end

function WeaponService:_attach(player, state)
	self:_detach(state)

	local character = state.Character
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

	local models = self._weapon_models
	if not models then
		warn("[WeaponService] ServerStorage.weapon_models is missing")
		return
	end

	local model = models:FindFirstChild(weapon.Model)
	if not model then
		warn(("[WeaponService] Missing model %q for player %s"):format(
			tostring(weapon.Model),
			player.Name
		))
		return
	end

	local clone = WeaponAttachment.Attach(model, weapon.Wield, character)
	if not clone then
		-- WeaponAttachment reports the model or binding failure with its source path.
		return
	end

	local attach_trove = state.CharacterTrove:Extend()
	attach_trove:Add(clone)

	local wielded = { Model = clone }
	for wield_name in pairs(weapon.Wield or {}) do
		local part = clone:FindFirstChild(wield_name, true)
		if part then
			wielded[wield_name] = part
		end
	end

	state.AttachTrove = attach_trove
	state.Wielded = wielded
end

function WeaponService:GetEquipped(player)
	local state = self:_state(player)
	return state and state.Equipped
end

function WeaponService:GetWielded(player, wield_name)
	local state = self:_state(player)
	local wielded = state and state.Wielded
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

	local state = self:_state(player)
	if not state then
		return false
	end

	local weapon = Catalog.Get(weapon_id)
	if not Catalog.IsEquippable(weapon) or typeof(weapon.Model) ~= "string" or weapon.Model == "" then
		return false
	end

	local models = self._weapon_models
	if not models or not models:FindFirstChild(weapon.Model) then
		warn(("[WeaponService] Cannot equip %q for player %s: model template is missing"):format(
			weapon_id,
			player.Name
		))
		return false
	end

	if state.Equipped == weapon then
		return true
	end

	state.Equipped = weapon
	self:_attach(player, state)

	self.EquippedChanged:Fire(player, weapon)
	self._remote:FireClient(player, Protocol.Weapon.Equipped, weapon_id)

	return true
end

function WeaponService:Destroy()
	for _, session in self._players:GetSessions() do
		local state = session:Get(self)
		if state then
			self:_detach(state)
		end
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return WeaponService
