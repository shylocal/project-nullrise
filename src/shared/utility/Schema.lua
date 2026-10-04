--!strict
-- Declarative data validation. A Spec describes the expected shape of a value;
-- Schema.check walks the value and returns every problem it finds (it never
-- stops at the first one). Records reject unknown keys unless opened.
--
-- Error strings are "<path>: <message>", where path is built like
-- `Katana.Moves.Light2.HitWindow`. Within a single value only the first failing
-- constraint is reported (e.g. a NaN is "must be finite", not also "must be > 0").
local Schema = {}

export type Spec = { kind: string, [string]: any }

export type NumberOptions = { gt: number?, gte: number?, lt: number?, lte: number?, integer: boolean? }
export type StringOptions = { nonEmpty: boolean?, pattern: string?, maxLength: number? }
export type RecordOptions = { open: boolean? }
export type MapOptions = { nonEmpty: boolean? }
export type ArrayOptions = { minLength: number? }

local IDENTIFIER_PATTERN = "^[%a_][%w_]*$"

-- Appends a key to a path. An empty base path yields the bare key, so the
-- config root can be checked with path "" and report `Movement.WalkSpeed`.
local function join(path: string, key: any): string
	if type(key) == "string" and string.match(key, IDENTIFIER_PATTERN) then
		if path == "" then
			return key
		end
		return path .. "." .. key
	elseif type(key) == "number" then
		return ("%s[%s]"):format(path, tostring(key))
	end
	return ("%s[%q]"):format(path, tostring(key))
end

local function fail(errors: { string }, path: string, message: string)
	table.insert(errors, ("%s: %s"):format(if path == "" then "(root)" else path, message))
end

local function format_number(value: number): string
	return tostring(value)
end

local function sorted_keys(value: { [any]: any }): { any }
	local keys = {}
	for key in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		local type_a, type_b = type(a), type(b)
		if type_a ~= type_b then
			return type_a < type_b
		end
		if type_a == "number" or type_a == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local check_into: (value: any, spec: Spec, path: string, errors: { string }) -> ()

local CHECKERS: { [string]: (value: any, spec: Spec, path: string, errors: { string }) -> () } = {}

function CHECKERS.number(value, spec, path, errors)
	if type(value) ~= "number" then
		fail(errors, path, "must be a number")
		return
	end
	if value ~= value or value == math.huge or value == -math.huge then
		fail(errors, path, "must be finite")
		return
	end
	local opts = spec.opts
	if opts.integer and value ~= math.floor(value) then
		fail(errors, path, "must be an integer")
		return
	end
	if opts.gt ~= nil and not (value > opts.gt) then
		fail(errors, path, "must be > " .. format_number(opts.gt))
		return
	end
	if opts.gte ~= nil and not (value >= opts.gte) then
		fail(errors, path, "must be >= " .. format_number(opts.gte))
		return
	end
	if opts.lt ~= nil and not (value < opts.lt) then
		fail(errors, path, "must be < " .. format_number(opts.lt))
		return
	end
	if opts.lte ~= nil and not (value <= opts.lte) then
		fail(errors, path, "must be <= " .. format_number(opts.lte))
		return
	end
end

function CHECKERS.string(value, spec, path, errors)
	if type(value) ~= "string" then
		fail(errors, path, "must be a string")
		return
	end
	local opts = spec.opts
	if opts.nonEmpty and value == "" then
		fail(errors, path, "must not be empty")
		return
	end
	if opts.maxLength ~= nil and #value > opts.maxLength then
		fail(errors, path, ("must be at most %d characters"):format(opts.maxLength))
		return
	end
	if opts.pattern ~= nil and string.match(value, opts.pattern) == nil then
		fail(errors, path, "must match " .. opts.pattern)
		return
	end
end

function CHECKERS.boolean(value, _spec, path, errors)
	if type(value) ~= "boolean" then
		fail(errors, path, "must be a boolean")
	end
end

function CHECKERS.enum(value, spec, path, errors)
	if type(value) == "string" and spec.lookup[value] then
		return
	end
	fail(errors, path, "must be one of: " .. table.concat(spec.values, ", "))
end

function CHECKERS.enumItem(value, spec, path, errors)
	if typeof(value) == "EnumItem" and (value :: EnumItem).EnumType == spec.enum then
		return
	end
	fail(errors, path, "must be an Enum." .. tostring(spec.enum))
end

function CHECKERS.optional(value, spec, path, errors)
	if value == nil then
		return
	end
	check_into(value, spec.inner, path, errors)
end

function CHECKERS.record(value, spec, path, errors)
	if type(value) ~= "table" then
		fail(errors, path, "must be a table")
		return
	end
	local fields: { [string]: Spec } = spec.fields
	for _, key in ipairs(spec.order) do
		local field_spec = fields[key]
		local field_value = value[key]
		local field_path = join(path, key)
		if field_value == nil and field_spec.kind ~= "optional" then
			fail(errors, field_path, "is required")
		else
			check_into(field_value, field_spec, field_path, errors)
		end
	end
	if not spec.opts.open then
		for _, key in ipairs(sorted_keys(value)) do
			if type(key) ~= "string" or fields[key] == nil then
				fail(errors, join(path, key), "unknown key")
			end
		end
	end
end

function CHECKERS.map(value, spec, path, errors)
	if type(value) ~= "table" then
		fail(errors, path, "must be a table")
		return
	end
	if spec.opts.nonEmpty and next(value) == nil then
		fail(errors, path, "must not be empty")
		return
	end
	for _, key in ipairs(sorted_keys(value)) do
		local entry_path = join(path, key)
		check_into(key, spec.key, entry_path, errors)
		check_into(value[key], spec.value, entry_path, errors)
	end
end

function CHECKERS.array(value, spec, path, errors)
	if type(value) ~= "table" then
		fail(errors, path, "must be a table")
		return
	end
	local length = #value
	local count = 0
	for key in pairs(value) do
		count += 1
		if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > length then
			fail(errors, path, "must be a dense array")
			return
		end
	end
	if count ~= length then
		fail(errors, path, "must be a dense array")
		return
	end
	local min_length = spec.opts.minLength
	if min_length ~= nil and length < min_length then
		fail(errors, path, ("must have at least %d entries"):format(min_length))
		return
	end
	for index = 1, length do
		check_into(value[index], spec.item, join(path, index), errors)
	end
end

function CHECKERS.custom(value, spec, path, errors)
	local message = spec.check(value, path)
	if message ~= nil then
		fail(errors, path, message)
	end
end

check_into = function(value: any, spec: Spec, path: string, errors: { string })
	local checker = CHECKERS[spec.kind]
	if checker == nil then
		error(("Schema: unknown spec kind '%s' at %s"):format(tostring(spec.kind), path), 2)
	end
	checker(value, spec, path, errors)
end

local function assert_spec(spec: any, label: string)
	if type(spec) ~= "table" or type(spec.kind) ~= "string" or CHECKERS[spec.kind] == nil then
		error(("Schema.%s: expected a Spec"):format(label), 3)
	end
end

function Schema.number(opts: NumberOptions?): Spec
	return table.freeze({ kind = "number", opts = table.freeze(table.clone(opts or {})) })
end

function Schema.string(opts: StringOptions?): Spec
	return table.freeze({ kind = "string", opts = table.freeze(table.clone(opts or {})) })
end

function Schema.boolean(): Spec
	return table.freeze({ kind = "boolean" })
end

function Schema.enum(values: { string }): Spec
	if type(values) ~= "table" or #values == 0 then
		error("Schema.enum: expected a non-empty list of strings", 2)
	end
	local lookup = {}
	for _, name in ipairs(values) do
		lookup[name] = true
	end
	return table.freeze({
		kind = "enum",
		values = table.freeze(table.clone(values)),
		lookup = table.freeze(lookup),
	})
end

function Schema.enumItem(enum: Enum): Spec
	if typeof(enum) ~= "Enum" then
		error("Schema.enumItem: expected an Enum", 2)
	end
	return table.freeze({ kind = "enumItem", enum = enum })
end

function Schema.optional(spec: Spec): Spec
	assert_spec(spec, "optional")
	return table.freeze({ kind = "optional", inner = spec })
end

function Schema.record(fields: { [string]: Spec }, opts: RecordOptions?): Spec
	local order = {}
	for key, field_spec in pairs(fields) do
		assert_spec(field_spec, "record")
		table.insert(order, key)
	end
	table.sort(order)
	return table.freeze({
		kind = "record",
		fields = table.freeze(table.clone(fields)),
		order = table.freeze(order),
		opts = table.freeze(table.clone(opts or {})),
	})
end

function Schema.map(key: Spec, value: Spec, opts: MapOptions?): Spec
	assert_spec(key, "map")
	assert_spec(value, "map")
	return table.freeze({ kind = "map", key = key, value = value, opts = table.freeze(table.clone(opts or {})) })
end

function Schema.array(item: Spec, opts: ArrayOptions?): Spec
	assert_spec(item, "array")
	return table.freeze({ kind = "array", item = item, opts = table.freeze(table.clone(opts or {})) })
end

-- `check` returns an error message (without the path prefix) or nil; Schema
-- prefixes it with the path.
function Schema.custom(check: (value: any, path: string) -> string?): Spec
	if type(check) ~= "function" then
		error("Schema.custom: expected a function", 2)
	end
	return table.freeze({ kind = "custom", check = check })
end

function Schema.check(value: any, spec: Spec, path: string): { string }
	assert_spec(spec, "check")
	local errors = {}
	check_into(value, spec, path, errors)
	return errors
end

return table.freeze(Schema)
