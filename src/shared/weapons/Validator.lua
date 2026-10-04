--!strict
-- Validates weapon definitions (schema v2: Moves, Combo, Bindings): a Schema
-- pass per weapon kind, then cross-field rules. Every problem is reported, not
-- just the first.
local Schema = require(script.Parent.Parent.utility.Schema)

local Validator = {}

-- Animation roles in declaration order. A later role that reuses an earlier
-- role's asset id must say so with SharedWith, so accidental copy-paste of an
-- id is caught while intentional sharing (Katana Idle/Sprint) is explicit.
local ROLE_ORDER = { "Equip", "Idle", "Sprint" }

-- Bindings.Primary.Tap value that cycles through Combo.
local COMBO_TAP = "Combo"
local MOVE_NAME_PATTERN = "^%a[%w_]*$"

local positive = Schema.number({ gt = 0 })
local non_negative = Schema.number({ gte = 0 })
local positive_integer = Schema.number({ gt = 0, integer = true })
local non_empty_string = Schema.string({ nonEmpty = true })

local ANIMATION = Schema.record({
	Id = Schema.string({ pattern = "^rbxassetid://%d+$" }),
	Priority = Schema.enumItem(Enum.AnimationPriority),
	Looped = Schema.boolean(),
	-- When omitted the animation plays with no blend.
	TransitionTime = Schema.optional(non_negative),
	SharedWith = Schema.optional(Schema.enum(ROLE_ORDER)),
})

-- Authored move fields. Name and Id are injected by the Catalog and checked
-- separately (forbidden in authored data, consistent in catalog data).
local MOVE_FIELDS: { [string]: Schema.Spec } = {
	Kind = Schema.enum({ "Light", "Charge" }),
	Animation = ANIMATION,
	Hitbox = non_empty_string,
	Damage = positive,
	Cooldown = non_negative,
	MinDuration = positive,
	HitStartAt = non_negative,
	HitWindow = positive,
	HitPositionTolerance = non_negative,
	Range = positive,
	CanSprintWhileAttacking = Schema.optional(Schema.boolean()),
	Hold = Schema.optional(Schema.record({ HoldTime = positive, MaxHoldTime = positive })),
}

local function with_fields(base: { [string]: Schema.Spec }, extra: { [string]: Schema.Spec }): { [string]: Schema.Spec }
	local fields = table.clone(base)
	for key, spec in pairs(extra) do
		fields[key] = spec
	end
	return fields
end

local function all_optional(fields: { [string]: Schema.Spec }): { [string]: Schema.Spec }
	local optional = {}
	for key, spec in pairs(fields) do
		optional[key] = if spec.kind == "optional" then spec else Schema.optional(spec)
	end
	return optional
end

local MOVE = Schema.record(with_fields(MOVE_FIELDS, {
	Name = Schema.optional(Schema.string({ pattern = MOVE_NAME_PATTERN })),
	Id = Schema.optional(positive_integer),
}))

local MELEE_SPEC = Schema.record({
	-- Injected by the Catalog; optional so catalog definitions re-validate.
	Id = Schema.optional(non_empty_string),
	Type = Schema.enum({ "Melee" }),
	Model = non_empty_string,
	CanSprintWhileAttacking = Schema.boolean(),
	Wield = Schema.map(non_empty_string, non_empty_string, { nonEmpty = true }),
	Animations = Schema.record({
		Equip = ANIMATION,
		Idle = ANIMATION,
		Sprint = ANIMATION,
	}),
	-- Shared move fields, shallow-merged into every move (authored keys win).
	MoveDefaults = Schema.optional(Schema.record(all_optional(MOVE_FIELDS))),
	Moves = Schema.map(Schema.string({ pattern = MOVE_NAME_PATTERN }), MOVE, { nonEmpty = true }),
	-- Light moves played in order by the Combo tap; the server cycles a cursor
	-- through it, so it must be a dense array.
	Combo = Schema.array(non_empty_string, { minLength = 1 }),
	Bindings = Schema.record({
		Primary = Schema.record({
			Tap = non_empty_string,
			Hold = Schema.optional(non_empty_string),
		}),
	}),
})

Validator.KINDS = table.freeze({
	Melee = MELEE_SPEC,
}) :: { [string]: Schema.Spec }

Validator.ComboTap = COMBO_TAP

local function kind_names(): string
	local names = {}
	for name in pairs(Validator.KINDS) do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function merge_defaults(defaults: { [any]: any }, move: any): any
	if type(move) ~= "table" then
		return move
	end
	local merged = table.clone(defaults)
	for key, value in pairs(move) do
		merged[key] = value
	end
	return merged
end

-- Returns a shallow copy of `definition` with MoveDefaults merged into each
-- move (authored keys win) and the MoveDefaults key removed. Returns the
-- input unchanged when there are no defaults to apply.
function Validator.resolve(definition: any): any
	if type(definition) ~= "table" or type(definition.MoveDefaults) ~= "table" then
		return definition
	end
	local defaults = definition.MoveDefaults
	local resolved = table.clone(definition)
	resolved.MoveDefaults = nil
	if type(definition.Moves) == "table" then
		local moves = {}
		for name, move in pairs(definition.Moves) do
			moves[name] = merge_defaults(defaults, move)
		end
		resolved.Moves = moves
	end
	return resolved
end

-- Move ids for a Moves table: string keys sorted with `<`, numbered from 1.
-- Non-string keys get no id (the schema reports them).
function Validator.move_ids(moves: any): { [string]: number }
	local ids: { [string]: number } = {}
	if type(moves) ~= "table" then
		return ids
	end
	local names = {}
	for name in pairs(moves) do
		if type(name) == "string" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for index, name in ipairs(names) do
		ids[name] = index
	end
	return ids
end

local function is_number(value: any): boolean
	return type(value) == "number" and value == value
end

local function check_move(move: any, path: string, errors: { string })
	if type(move) ~= "table" then
		return
	end
	if is_number(move.Cooldown) and is_number(move.MinDuration) and move.Cooldown < move.MinDuration then
		table.insert(errors, ("%s.Cooldown: must be >= MinDuration (%s)"):format(path, tostring(move.MinDuration)))
	end

	local hold = move.Hold
	if move.Kind == "Charge" and hold == nil then
		table.insert(errors, path .. ".Hold: is required for a Charge move")
	elseif move.Kind == "Light" and hold ~= nil then
		table.insert(errors, path .. ".Hold: is only allowed on a Charge move")
	end
	-- MaxHoldTime is measured from the move start, like HitStartAt.
	if type(hold) == "table" and is_number(hold.MaxHoldTime) and is_number(move.HitStartAt) and hold.MaxHoldTime <= move.HitStartAt then
		table.insert(errors, ("%s.Hold.MaxHoldTime: must be > HitStartAt (%s)"):format(path, tostring(move.HitStartAt)))
	end
end

-- Name and Id belong to the Catalog: an authored definition (no weapon Id)
-- must not set them, and a catalog definition must carry the injected values.
local function check_injected(definition: any, moves: { [any]: any }, path: string, errors: { string })
	local is_catalog = definition.Id ~= nil
	local ids = Validator.move_ids(moves)
	for name, move in pairs(moves) do
		if type(name) ~= "string" or type(move) ~= "table" then
			continue
		end
		local move_path = ("%s.Moves.%s"):format(path, name)
		if not is_catalog then
			if move.Name ~= nil then
				table.insert(errors, move_path .. ".Name: is injected by the Catalog")
			end
			if move.Id ~= nil then
				table.insert(errors, move_path .. ".Id: is injected by the Catalog")
			end
		else
			if move.Name ~= nil and move.Name ~= name then
				table.insert(errors, ("%s.Name: must be %s"):format(move_path, name))
			end
			if move.Id ~= nil and move.Id ~= ids[name] then
				table.insert(errors, ("%s.Id: must be %d"):format(move_path, ids[name]))
			end
		end
	end
end

-- (exists, kind) for a move name. The kind is nil when the move is missing
-- or its Kind is malformed (the schema reports that).
local function move_kind(moves: { [any]: any }, name: any): (boolean, string?)
	local move = if type(name) == "string" then moves[name] else nil
	if type(move) ~= "table" then
		return false, nil
	end
	return true, if type(move.Kind) == "string" then move.Kind else nil
end

local function check_moves(definition: any, path: string, errors: { string })
	local moves = definition.Moves
	if type(moves) ~= "table" then
		return
	end

	for name, move in pairs(moves) do
		if type(name) == "string" then
			check_move(move, ("%s.Moves.%s"):format(path, name), errors)
		end
	end
	check_injected(definition, moves, path, errors)

	if moves[COMBO_TAP] ~= nil then
		table.insert(errors, ("%s.Moves.%s: is a reserved name"):format(path, COMBO_TAP))
	end

	local reachable: { [string]: boolean } = {}

	local combo = definition.Combo
	if type(combo) == "table" then
		for index, name in ipairs(combo) do
			if type(name) ~= "string" then
				continue
			end
			local exists, kind = move_kind(moves, name)
			if not exists then
				table.insert(errors, ("%s.Combo[%d]: %s is not a move"):format(path, index, name))
			elseif kind ~= nil and kind ~= "Light" then
				table.insert(errors, ("%s.Combo[%d]: %s must be a Light move"):format(path, index, name))
			end
			reachable[name] = true
		end
	end

	local bindings = definition.Bindings
	local primary = if type(bindings) == "table" then bindings.Primary else nil
	if type(primary) == "table" then
		local tap = primary.Tap
		if type(tap) == "string" and tap ~= COMBO_TAP then
			if not (move_kind(moves, tap)) then
				table.insert(errors, ("%s.Bindings.Primary.Tap: must be %s or a move name"):format(path, COMBO_TAP))
			end
			reachable[tap] = true
		end

		local hold = primary.Hold
		if type(hold) == "string" then
			local exists, kind = move_kind(moves, hold)
			if not exists then
				table.insert(errors, ("%s.Bindings.Primary.Hold: %s is not a move"):format(path, hold))
			elseif kind ~= nil and kind ~= "Charge" then
				table.insert(errors, ("%s.Bindings.Primary.Hold: %s must be a Charge move"):format(path, hold))
			end
			reachable[hold] = true
		end
	end

	for name in pairs(moves) do
		if type(name) == "string" and not reachable[name] then
			table.insert(errors, ("%s.Moves.%s: is not reachable from Combo or Bindings"):format(path, name))
		end
	end
end

local function check_shared_animations(animations: any, path: string, errors: { string })
	if type(animations) ~= "table" then
		return
	end
	for index, role in ipairs(ROLE_ORDER) do
		local animation = animations[role]
		if type(animation) == "table" and type(animation.Id) == "string" then
			local shared_with = animation.SharedWith
			local first_match = nil
			for earlier = 1, index - 1 do
				local other = animations[ROLE_ORDER[earlier]]
				if type(other) == "table" and other.Id == animation.Id then
					first_match = first_match or ROLE_ORDER[earlier]
					if shared_with == ROLE_ORDER[earlier] then
						first_match = shared_with
						break
					end
				end
			end
			local role_path = ("%s.Animations.%s.SharedWith"):format(path, role)
			if first_match ~= nil and shared_with ~= first_match then
				table.insert(errors, ("%s: must be %s (same animation Id)"):format(role_path, first_match))
			elseif first_match == nil and shared_with ~= nil then
				table.insert(errors, ("%s: must name an earlier role with the same animation Id"):format(role_path))
			end
		end
	end
end

-- Returns every problem with `definition`, each prefixed with `id`. An unknown
-- Type is the only error reported for that definition, since the remaining
-- rules depend on the kind.
function Validator.check(definition: any, id: string): { string }
	if type(definition) ~= "table" then
		return { id .. ": must be a table" }
	end
	local kind = definition.Type
	if kind == nil then
		return { id .. ".Type: is required" }
	end
	local spec = if type(kind) == "string" then Validator.KINDS[kind] else nil
	if spec == nil then
		return { ("%s.Type: must be one of: %s"):format(id, kind_names()) }
	end

	local resolved = Validator.resolve(definition)
	local errors = Schema.check(resolved, spec, id)
	-- MoveDefaults itself is checked on the authored definition.
	if definition.MoveDefaults ~= nil then
		for _, message in ipairs(Schema.check(definition, spec, id)) do
			if string.find(message, id .. ".MoveDefaults", 1, true) == 1 then
				table.insert(errors, message)
			end
		end
	end
	check_moves(resolved, id, errors)
	check_shared_animations(resolved.Animations, id, errors)
	return errors
end

-- check() as (true) or (false, every error joined by newlines).
function Validator.validate(definition: any, id: string?): (boolean, string?)
	local errors = Validator.check(definition, id or "definition")
	if #errors > 0 then
		return false, table.concat(errors, "\n")
	end
	return true, nil
end

return table.freeze(Validator)
