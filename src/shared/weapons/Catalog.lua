--!strict
-- Central weapon-definition lookup shared by client and server.
-- Weapon definitions are ModuleScripts beside this file. Only ids listed in
-- WEAPON_IDS are weapons; other modules here (Validator, Loadouts, this
-- Catalog, ...) are never returned by Get.
--
-- Every definition is validated when the catalog is first required, and all
-- problems across all weapons are raised in one error: invalid content is a
-- bug, so combat never runs with partially defined data. Returned definitions
-- are deep-frozen copies with `Id` injected.
local Config = require(script.Parent.Parent.config)
local Freeze = require(script.Parent.Parent.utility.Freeze)
local AnimationContracts = require(script.Parent.AnimationContracts)
local AnimationManifest = require(script.Parent.AnimationManifest)
local Loadouts = require(script.Parent.Loadouts)
local Types = require(script.Parent.Types)
local Validator = require(script.Parent.Validator)

export type WeaponDefinition = Types.WeaponDefinition
export type MoveDef = Types.MoveDef

local WEAPON_IDS = {
	"Fists",
	"Katana",
}

-- The weapon a player holds with nothing selected. The only place this id is named.
local DEFAULT_ID = "Fists"

local WeaponsFolder = script.Parent

local Catalog = {}

Catalog.DefaultId = DEFAULT_ID

local definitions: { [string]: WeaponDefinition } = {}
local moves_by_id: { [string]: { [number]: MoveDef } } = {}
local ordered: { WeaponDefinition } = {}
local loadouts: { [string]: { [number]: string } } = {}

local function load_definitions(): { string }
	local errors = {}
	local authored: { [string]: any } = {}
	for _, weapon_id in ipairs(WEAPON_IDS) do
		local module = WeaponsFolder:FindFirstChild(weapon_id)
		if module == nil or not module:IsA("ModuleScript") then
			table.insert(errors, ("%s: definition module is missing from %s"):format(weapon_id, WeaponsFolder:GetFullName()))
			continue
		end
		local definition = (require :: any)(module)
		for _, message in ipairs(Validator.check(definition, weapon_id)) do
			table.insert(errors, message)
		end
		for _, message in ipairs(AnimationContracts.check(definition, weapon_id, AnimationManifest)) do
			table.insert(errors, message)
		end
		authored[weapon_id] = definition
	end
	if #errors > 0 then
		return errors
	end

	for _, weapon_id in ipairs(WEAPON_IDS) do
		-- The authored module table stays untouched; the catalog owns a copy
		-- with MoveDefaults applied and the weapon Id and move Name/Id injected.
		local definition = Freeze.clone_deep(Validator.resolve(authored[weapon_id]))
		definition.Id = weapon_id
		local by_id = {}
		for name, move_id in pairs(Validator.move_ids(definition.Moves)) do
			local move = definition.Moves[name]
			move.Name = name
			move.Id = move_id
			by_id[move_id] = move
		end
		Freeze.deep(definition)
		definitions[weapon_id] = definition
		moves_by_id[weapon_id] = table.freeze(by_id)
		table.insert(ordered, definition)
	end
	return errors
end

local function load_loadouts(): { string }
	local errors = {}
	local max_slots = Config.Inventory.MaxSlots
	for name, loadout in pairs(Loadouts :: { [any]: any }) do
		local path = ("Loadouts.%s"):format(tostring(name))
		if type(name) ~= "string" or type(loadout) ~= "table" then
			table.insert(errors, path .. ": must be a table keyed by loadout name")
			continue
		end
		for slot, weapon_id in pairs(loadout) do
			local slot_path = ("%s[%s]"):format(path, tostring(slot))
			if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 1 or slot > max_slots then
				table.insert(errors, ("%s: slot must be an integer in 1..%d"):format(slot_path, max_slots))
			end
			local definition = if type(weapon_id) == "string" then definitions[weapon_id] else nil
			if definition == nil or Validator.KINDS[definition.Type] == nil then
				table.insert(errors, ("%s: %s is not an equippable weapon id"):format(slot_path, tostring(weapon_id)))
			elseif weapon_id == DEFAULT_ID then
				table.insert(errors, ("%s: must not be the default weapon %s"):format(slot_path, DEFAULT_ID))
			end
		end
		loadouts[name] = Freeze.deep(table.clone(loadout))
	end
	return errors
end

do
	local errors = load_definitions()
	if #errors == 0 then
		errors = load_loadouts()
	end
	if definitions[DEFAULT_ID] == nil and #errors == 0 then
		table.insert(errors, ("DefaultId %s is not a catalog weapon"):format(DEFAULT_ID))
	end
	if #errors > 0 then
		error("Invalid weapon catalog:\n" .. table.concat(errors, "\n"), 0)
	end
end

local frozen_ids = table.freeze(table.clone(WEAPON_IDS))
table.freeze(ordered)

-- Weapon ids in declaration order (frozen).
function Catalog.Ids(): { string }
	return frozen_ids
end

-- Definitions in Ids() order (frozen).
function Catalog.All(): { WeaponDefinition }
	return ordered
end

function Catalog.Get(weapon_id: any): WeaponDefinition?
	if type(weapon_id) ~= "string" then
		return nil
	end
	return definitions[weapon_id]
end

function Catalog.Has(weapon_id: any): boolean
	return type(weapon_id) == "string" and definitions[weapon_id] ~= nil
end

-- True for a definition of a catalog weapon (identified by its injected Id)
-- whose Type has a validator kind. Copies of catalog definitions (e.g. specs
-- that tweak one attack) keep their Id and still count.
function Catalog.IsEquippable(definition: any): boolean
	return type(definition) == "table"
		and type(definition.Id) == "string"
		and definitions[definition.Id] ~= nil
		and type(definition.Type) == "string"
		and Validator.KINDS[definition.Type] ~= nil
end

-- The move of a catalog weapon with this id, or nil for an unknown weapon or
-- id (any value is accepted, so remote payloads can be passed straight in).
function Catalog.GetMove(weapon_id: string, move_id: any): MoveDef?
	local by_id = moves_by_id[weapon_id]
	if by_id == nil or type(move_id) ~= "number" then
		return nil
	end
	return by_id[move_id]
end

function Catalog.MoveId(weapon_id: string, name: string): number?
	local definition = definitions[weapon_id]
	local move = definition and definition.Moves[name]
	return move and move.Id
end

-- Move id of the `index`-th Combo entry of `weapon` (a catalog definition or
-- a copy of one). Errors for an index outside 1..#weapon.Combo.
function Catalog.ComboMoveId(weapon: WeaponDefinition, index: number): number
	local name = weapon.Combo[index]
	local move = name and weapon.Moves[name]
	if move == nil then
		error(("Catalog.ComboMoveId: %s has no combo entry %s"):format(tostring(weapon.Id), tostring(index)), 2)
	end
	return move.Id
end

-- Frozen slot -> weapon id map for a named loadout. Errors on an unknown name.
function Catalog.Loadout(name: string): { [number]: string }
	local loadout = loadouts[name]
	if loadout == nil then
		error(("Catalog.Loadout: unknown loadout '%s'"):format(tostring(name)), 2)
	end
	return loadout
end

return table.freeze(Catalog)
