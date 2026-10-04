--!strict
-- Validates authored weapon definitions: a Schema pass per weapon kind, then
-- cross-field rules. Every problem is reported, not just the first.
local Schema = require(script.Parent.Parent.utility.Schema)

local Validator = {}

-- Animation roles in declaration order. A later role that reuses an earlier
-- role's asset id must say so with SharedWith, so accidental copy-paste of an
-- id is caught while intentional sharing (Katana Idle/Sprint) is explicit.
local ROLE_ORDER = { "Equip", "Idle", "Sprint", "Charge" }

local positive = Schema.number({ gt = 0 })
local non_negative = Schema.number({ gte = 0 })
local non_empty_string = Schema.string({ nonEmpty = true })

local ANIMATION = Schema.record({
	Id = Schema.string({ pattern = "^rbxassetid://%d+$" }),
	Priority = Schema.enumItem(Enum.AnimationPriority),
	Looped = Schema.boolean(),
	-- When omitted the animation plays with no blend.
	TransitionTime = Schema.optional(non_negative),
	SharedWith = Schema.optional(Schema.enum(ROLE_ORDER)),
})

local ATTACK_FIELDS: { [string]: Schema.Spec } = {
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

local CHARGE_FIELDS = with_fields(ATTACK_FIELDS, { HoldTime = positive, MaxHoldTime = positive })

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
		Charge = Schema.optional(ANIMATION),
	}),
	-- Attacks are a combo sequence indexed 1..n; the server cycles through them
	-- by index, so the table must be a dense array.
	Attacks = Schema.array(Schema.record(ATTACK_FIELDS), { minLength = 1 }),
	Charge = Schema.optional(Schema.record(CHARGE_FIELDS)),
	-- Shared attack fields, shallow-merged into every attack and the charge.
	AttackDefaults = Schema.optional(Schema.record(all_optional(CHARGE_FIELDS))),
})

Validator.KINDS = table.freeze({
	Melee = MELEE_SPEC,
}) :: { [string]: Schema.Spec }

local function kind_names(): string
	local names = {}
	for name in pairs(Validator.KINDS) do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function merge_defaults(defaults: { [any]: any }, attack: any): any
	if type(attack) ~= "table" then
		return attack
	end
	local merged = table.clone(defaults)
	for key, value in pairs(attack) do
		merged[key] = value
	end
	return merged
end

-- Returns a shallow copy of `definition` with AttackDefaults merged into each
-- attack and the charge (authored keys win) and the AttackDefaults key
-- removed. Returns the input unchanged when there are no defaults to apply.
function Validator.resolve(definition: any): any
	if type(definition) ~= "table" or type(definition.AttackDefaults) ~= "table" then
		return definition
	end
	local defaults = definition.AttackDefaults
	local resolved = table.clone(definition)
	resolved.AttackDefaults = nil
	if type(definition.Attacks) == "table" then
		local attacks = {}
		for key, attack in pairs(definition.Attacks) do
			attacks[key] = merge_defaults(defaults, attack)
		end
		resolved.Attacks = attacks
	end
	if definition.Charge ~= nil then
		resolved.Charge = merge_defaults(defaults, definition.Charge)
	end
	return resolved
end

local function is_number(value: any): boolean
	return type(value) == "number" and value == value
end

local function check_attack_timing(attack: any, path: string, errors: { string })
	if type(attack) ~= "table" then
		return
	end
	if is_number(attack.Cooldown) and is_number(attack.MinDuration) and attack.Cooldown < attack.MinDuration then
		table.insert(errors, ("%s.Cooldown: must be >= MinDuration (%s)"):format(path, tostring(attack.MinDuration)))
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

local function check_cross_fields(definition: any, path: string, errors: { string })
	if type(definition.Attacks) == "table" then
		for index, attack in ipairs(definition.Attacks) do
			check_attack_timing(attack, ("%s.Attacks[%d]"):format(path, index), errors)
		end
	end

	local charge = definition.Charge
	local animations = definition.Animations
	local has_charge_animation = type(animations) == "table" and animations.Charge ~= nil
	if type(charge) == "table" then
		check_attack_timing(charge, path .. ".Charge", errors)
		-- MaxHoldTime is measured from the charge start, like HitStartAt.
		if is_number(charge.MaxHoldTime) and is_number(charge.HitStartAt) and charge.MaxHoldTime <= charge.HitStartAt then
			table.insert(errors, ("%s.Charge.MaxHoldTime: must be > HitStartAt (%s)"):format(path, tostring(charge.HitStartAt)))
		end
		if type(animations) == "table" and not has_charge_animation then
			table.insert(errors, path .. ".Animations.Charge: is required")
		end
	elseif charge == nil and has_charge_animation then
		table.insert(errors, path .. ".Animations.Charge: is only allowed with a Charge")
	end

	check_shared_animations(animations, path, errors)
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
	-- AttackDefaults itself is checked on the authored definition.
	if definition.AttackDefaults ~= nil then
		for _, message in ipairs(Schema.check(definition, spec, id)) do
			if string.find(message, id .. ".AttackDefaults", 1, true) == 1 then
				table.insert(errors, message)
			end
		end
	end
	check_cross_fields(resolved, id, errors)
	return errors
end

-- Compatibility wrapper: (true) or (false, errors joined by newlines).
function Validator.validate(definition: any, id: string?): (boolean, string?)
	local errors = Validator.check(definition, id or "definition")
	if #errors > 0 then
		return false, table.concat(errors, "\n")
	end
	return true, nil
end

return table.freeze(Validator)
