local Validator = {}

local REQUIRED_ANIMATIONS = { "Equip", "Idle", "Sprint", "Charge" }

local function is_finite_number(value)
	return typeof(value) == "number" and math.isfinite(value)
end

local function valid_animation(animation)
	return typeof(animation) == "table"
		and typeof(animation.Id) == "string"
		and string.match(animation.Id, "^rbxassetid://%d+$") ~= nil
		and animation.Priority ~= nil
		and typeof(animation.Looped) == "boolean"
end

local function valid_attack(attack)
	return typeof(attack) == "table"
		and typeof(attack.Hitbox) == "string"
		and attack.Hitbox ~= ""
		and is_finite_number(attack.Damage)
		and attack.Damage > 0
		and is_finite_number(attack.Cooldown)
		and attack.Cooldown >= 0
		and is_finite_number(attack.HitPositionTolerance)
		and attack.HitPositionTolerance >= 0
		and is_finite_number(attack.Range)
		and attack.Range > 0
		and valid_animation(attack.Animation)
end

function Validator.validate(definition)
	if typeof(definition) ~= "table" then
		return false, "definition must be a table"
	end
	if definition.Type ~= "Melee" then
		return true
	end
	if typeof(definition.Model) ~= "string" or definition.Model == "" then
		return false, "missing melee model"
	end
	if typeof(definition.CanSprintWhileAttacking) ~= "boolean" then
		return false, "missing sprint-attack policy"
	end
	if typeof(definition.Wield) ~= "table" or next(definition.Wield) == nil then
		return false, "missing wield bindings"
	end
	for name, body_part in pairs(definition.Wield) do
		if typeof(name) ~= "string" or name == "" then
			return false, "invalid wield name"
		end
		if typeof(body_part) ~= "string" or body_part == "" then
			return false, "invalid wield body part"
		end
	end
	if typeof(definition.Animations) ~= "table" then
		return false, "missing animations"
	end
	for _, animation_name in ipairs(REQUIRED_ANIMATIONS) do
		if not valid_animation(definition.Animations[animation_name]) then
			return false, ("invalid %s animation"):format(animation_name)
		end
	end
	if typeof(definition.Attacks) ~= "table" then
		return false, "missing attacks"
	end
	if not valid_attack(definition.Attacks[1]) or not valid_attack(definition.Attacks[2]) then
		return false, "invalid attack definition"
	end
	if not valid_attack(definition.Charge) then
		return false, "invalid charge definition"
	end
	if not is_finite_number(definition.Charge.HoldTime) or definition.Charge.HoldTime <= 0 then
		return false, "invalid charge hold time"
	end
	return true
end

return Validator
