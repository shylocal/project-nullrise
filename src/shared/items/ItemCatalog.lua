--!strict
-- Every item a player can own. An item is a persistent thing in an inventory
-- slot; a weapon item points at a Catalog weapon. The default weapon
-- (Catalog.DefaultId) is implicit and is never an item.
--
-- Items are validated when this module is first required (all errors raised
-- at once) and the catalog is deep-frozen with `Id` injected.
local Catalog = require(script.Parent.Parent.weapons.Catalog)
local Freeze = require(script.Parent.Parent.utility.Freeze)
local Loadouts = require(script.Parent.Parent.weapons.Loadouts)
local Schema = require(script.Parent.Parent.utility.Schema)

export type ItemKind = "Weapon"
export type ItemDef = { Id: string, Kind: ItemKind, WeaponId: string, Stackable: boolean }

local ITEMS: { [string]: any } = {
	Katana = { Kind = "Weapon", WeaponId = "Katana", Stackable = false },
}

local ITEM_SPEC = Schema.record({
	Kind = Schema.enum({ "Weapon" }),
	WeaponId = Schema.string({ nonEmpty = true }),
	Stackable = Schema.boolean(),
})

local ItemCatalog = {}

-- Pure: validates an item table shaped like ITEMS and returns every error.
-- Specs call it with broken copies.
function ItemCatalog.check(items: any): { string }
	if type(items) ~= "table" then
		return { "Items: must be a table" }
	end

	local errors: { string } = {}
	for id, item in pairs(items) do
		local path = ("Items.%s"):format(tostring(id))
		if type(id) ~= "string" or not string.match(id, "^%a[%w_]*$") then
			table.insert(errors, path .. ": item id must match ^%a[%w_]*$")
			continue
		end

		local item_errors = Schema.check(item, ITEM_SPEC, path)
		for _, message in item_errors do
			table.insert(errors, message)
		end
		if #item_errors > 0 then
			continue
		end

		local weapon_id = item.WeaponId
		if not Catalog.IsEquippable(Catalog.Get(weapon_id)) then
			table.insert(errors, ("%s.WeaponId: %s is not an equippable weapon id"):format(path, weapon_id))
		elseif weapon_id == Catalog.DefaultId then
			table.insert(errors, ("%s.WeaponId: must not be the default weapon %s"):format(path, weapon_id))
		end
	end

	table.sort(errors)
	return errors
end

local definitions: { [string]: ItemDef } = {}
local by_weapon: { [string]: ItemDef } = {}
local ids: { string } = {}

do
	local errors = ItemCatalog.check(ITEMS)
	if #errors > 0 then
		error("Invalid item catalog:\n" .. table.concat(errors, "\n"), 0)
	end

	for id in pairs(ITEMS) do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ids do
		local item = Freeze.clone_deep(ITEMS[id])
		item.Id = id
		local definition: ItemDef = Freeze.deep(item)
		definitions[id] = definition
		-- Ids are sorted, so the first item for a weapon is deterministic.
		if by_weapon[definition.WeaponId] == nil then
			by_weapon[definition.WeaponId] = definition
		end
	end

	table.freeze(ids)

	-- Loadouts name weapons; seeding a profile turns each into its item.
	local loadout_errors: { string } = {}
	for name, loadout in pairs(Loadouts :: { [any]: any }) do
		for slot, weapon_id in pairs(loadout) do
			if by_weapon[weapon_id] == nil then
				table.insert(loadout_errors, ("Loadouts.%s[%s]: no item grants weapon %s"):format(
					tostring(name),
					tostring(slot),
					tostring(weapon_id)
				))
			end
		end
	end
	if #loadout_errors > 0 then
		table.sort(loadout_errors)
		error("Invalid item catalog:\n" .. table.concat(loadout_errors, "\n"), 0)
	end
end

-- Item ids, sorted (frozen).
function ItemCatalog.Ids(): { string }
	return ids
end

function ItemCatalog.Get(id: unknown): ItemDef?
	if type(id) ~= "string" then
		return nil
	end
	return definitions[id]
end

-- The first item (in Ids() order) that grants the given weapon.
function ItemCatalog.ForWeapon(weapon_id: unknown): ItemDef?
	if type(weapon_id) ~= "string" then
		return nil
	end
	return by_weapon[weapon_id]
end

return table.freeze(ItemCatalog)
