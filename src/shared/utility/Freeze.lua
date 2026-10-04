--!strict
-- Deep freeze / deep clone helpers for immutable shared data (config, weapon
-- definitions). Both walk every nested table exactly once, so cycles and
-- shared references are safe; non-table values are returned unchanged.
local Freeze = {}

local function freeze_into(value: any, seen: { [any]: boolean })
	if type(value) ~= "table" or seen[value] then
		return
	end
	seen[value] = true
	for key, child in pairs(value) do
		freeze_into(key, seen)
		freeze_into(child, seen)
	end
	if not table.isfrozen(value) then
		table.freeze(value)
	end
end

-- Freezes `value` and every table reachable from it (keys included). Already
-- frozen tables are still walked, because a frozen parent may hold mutable
-- children. Returns `value` for chaining.
function Freeze.deep<T>(value: T): T
	freeze_into(value, {})
	return value
end

local function clone_into(value: any, copies: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	local existing = copies[value]
	if existing ~= nil then
		return existing
	end
	local copy = {}
	-- Register before recursing so cycles resolve to the copy.
	copies[value] = copy
	for key, child in pairs(value) do
		copy[clone_into(key, copies)] = clone_into(child, copies)
	end
	return copy
end

-- Returns an unfrozen deep copy of `value`. A table referenced from several
-- places is copied once and the copy is shared the same way; metatables are
-- not copied (shared data never carries one).
function Freeze.clone_deep<T>(value: T): T
	return clone_into(value, {})
end

return table.freeze(Freeze)
