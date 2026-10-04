--!strict
-- The persisted player profile: its current shape, the template new profiles
-- start from, the migration chain and load-time sanitising.
--
-- Inventory slots are keyed by the slot number as a string ("1".."9"), so the
-- saved data never contains a sparse array. The selection is not persisted.
local ItemCatalog = require(script.Parent.Parent.items.ItemCatalog)

export type SlotRecord = { Uid: string, ItemId: string, Data: { [string]: any } }
export type ProfileDataV1 = {
	Version: number,
	Inventory: { Slots: { [string]: SlotRecord }, Seeded: boolean },
}
export type Migration = (data: any) -> ()

local VERSION = 1

local Schema = {}

Schema.Version = VERSION

-- Migrations[n] upgrades data from version n to n + 1 in place. The loader
-- bumps Version after each step. Empty while the schema is at version 1.
Schema.Migrations = table.freeze({}) :: { [number]: Migration }

function Schema.Template(): ProfileDataV1
	return {
		Version = VERSION,
		Inventory = {
			Slots = {},
			Seeded = false,
		},
	}
end

local function is_integer(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) ~= math.huge
end

-- Pure migration runner behind Schema.migrate, with the chain and the target
-- version passed in so specs can exercise the hook with their own steps.
function Schema.run_migrations(data: any, migrations: { [number]: Migration }, target: number): (any, string?)
	if type(data) ~= "table" then
		return nil, "profile data must be a table"
	end

	local version = data.Version
	if not is_integer(version) or version < 1 then
		return nil, ("profile Version must be a positive integer, got %s"):format(tostring(version))
	end
	if version > target then
		return nil, ("profile Version %d is newer than this server's schema (%d)"):format(version, target)
	end

	while version < target do
		local migration = migrations[version]
		if migration == nil then
			return nil, ("no migration from version %d"):format(version)
		end
		local ok, err = pcall(migration :: (any) -> any, data)
		if not ok then
			return nil, ("migration from version %d failed: %s"):format(version, tostring(err))
		end
		version += 1
		data.Version = version
	end

	return data, nil
end

-- Upgrades data in place to Schema.Version and checks the top-level shape.
-- Individual slot records are checked by sanitize, which drops bad ones
-- instead of failing the whole load.
function Schema.migrate(data: any): (ProfileDataV1?, string?)
	local migrated, err = Schema.run_migrations(data, Schema.Migrations, VERSION)
	if migrated == nil then
		return nil, err
	end

	local inventory = migrated.Inventory
	if type(inventory) ~= "table" then
		return nil, "Inventory must be a table"
	end
	if type(inventory.Slots) ~= "table" then
		return nil, "Inventory.Slots must be a table"
	end
	if type(inventory.Seeded) ~= "boolean" then
		return nil, "Inventory.Seeded must be a boolean"
	end

	return migrated :: ProfileDataV1, nil
end

local function slot_number(key: any, max_slots: number): number?
	if type(key) ~= "string" then
		return nil
	end
	local slot = tonumber(key)
	if slot == nil or not is_integer(slot) or slot < 1 or slot > max_slots or tostring(slot) ~= key then
		return nil
	end
	return slot
end

local function record_problem(record: any): string?
	if type(record) ~= "table" then
		return "record is not a table"
	end
	if type(record.Uid) ~= "string" or record.Uid == "" then
		return "Uid is missing"
	end
	if type(record.ItemId) ~= "string" or ItemCatalog.Get(record.ItemId) == nil then
		return ("unknown ItemId %s"):format(tostring(record.ItemId))
	end
	if type(record.Data) ~= "table" then
		return "Data is not a table"
	end
	return nil
end

-- Drops every slot whose key is not "1".."max_slots", whose record is
-- malformed or names an unknown item, or whose Uid repeats one in a lower
-- slot. Returns one warning per dropped slot.
function Schema.sanitize(data: ProfileDataV1, max_slots: number): { string }
	local warnings: { string } = {}
	local slots = data.Inventory.Slots

	local keys: { any } = {}
	for key in pairs(slots :: { [any]: any }) do
		table.insert(keys, key)
	end
	-- Valid slot keys first in slot order, then the invalid ones, so the
	-- lower slot keeps a duplicated Uid.
	table.sort(keys, function(a, b)
		local slot_a = slot_number(a, max_slots)
		local slot_b = slot_number(b, max_slots)
		if slot_a and slot_b then
			return slot_a < slot_b
		elseif slot_a or slot_b then
			return slot_a ~= nil
		end
		return tostring(a) < tostring(b)
	end)

	local seen_uids: { [string]: boolean } = {}
	for _, key in keys do
		local record = (slots :: any)[key]
		local problem: string?
		if slot_number(key, max_slots) == nil then
			problem = "invalid slot key"
		else
			problem = record_problem(record)
			if problem == nil and seen_uids[record.Uid] then
				problem = ("duplicate Uid %s"):format(record.Uid)
			end
		end

		if problem then
			table.insert(warnings, ("Inventory.Slots[%s]: %s; dropped"):format(tostring(key), problem))
			;(slots :: any)[key] = nil
		else
			seen_uids[record.Uid] = true
		end
	end

	return warnings
end

return table.freeze(Schema)
