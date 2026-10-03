local Validator = {}

local REQUIRED_ANIMATIONS = { "Equip", "Idle", "Sprint", "Charge" }

local function is_finite_number(value)
	return typeof(value) == "number" and math.isfinite(value)
end

local function is_positive(value)
	return is_finite_number(value) and value > 0
end

local function is_non_negative(value)
	return is_finite_number(value) and value >= 0
end

local function valid_animation(animation)
	return typeof(animation) == "table"
		and typeof(animation.Id) == "string"
		and string.match(animation.Id, "^rbxassetid://%d+$") ~= nil
		and animation.Priority ~= nil
		and typeof(animation.Looped) == "boolean"
		-- TransitionTime is optional; when omitted the animation plays with
		-- no blend.
		and (animation.TransitionTime == nil or is_non_negative(animation.TransitionTime))
end

-- Timing fields are measured in seconds from the moment the attack starts:
--   HitStartAt   earliest time the HitStart marker can be reached
--   HitWindow    how long hits stay valid after HitStartAt
--   MinDuration  earliest time the next attack may start (server enforced)
--   Cooldown     client-side input cooldown; never shorter than MinDuration
local function validate_attack(attack)
	if typeof(attack) ~= "table" then
		return false, "must be a table"
	end
	if typeof(attack.Hitbox) ~= "string" or attack.Hitbox == "" then
		return false, "invalid Hitbox"
	end
	if not is_positive(attack.Damage) then
		return false, "invalid Damage"
	end
	if not is_non_negative(attack.HitPositionTolerance) then
		return false, "invalid HitPositionTolerance"
	end
	if not is_positive(attack.Range) then
		return false, "invalid Range"
	end
	if not is_non_negative(attack.HitStartAt) then
		return false, "invalid HitStartAt"
	end
	if not is_positive(attack.HitWindow) then
		return false, "invalid HitWindow"
	end
	if not is_positive(attack.MinDuration) then
		return false, "invalid MinDuration"
	end
	if not is_finite_number(attack.Cooldown) or attack.Cooldown < attack.MinDuration then
		return false, "Cooldown must be a number no shorter than MinDuration"
	end
	if not valid_animation(attack.Animation) then
		return false, "invalid Animation"
	end
	return true
end

local function validate_charge(charge)
	local ok, reason = validate_attack(charge)
	if not ok then
		return false, reason
	end
	if not is_positive(charge.HoldTime) then
		return false, "invalid HoldTime"
	end
	-- MaxHoldTime is measured from the charge start, like HitStartAt.
	if not is_finite_number(charge.MaxHoldTime) or charge.MaxHoldTime <= charge.HitStartAt then
		return false, "MaxHoldTime must be a number greater than HitStartAt"
	end
	return true
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
	if typeof(definition.Attacks) ~= "table" or #definition.Attacks == 0 then
		return false, "missing attacks"
	end
	-- Attacks are a combo sequence indexed 1..n; the server cycles through
	-- them by index, so the table must be a dense array.
	local attack_count = 0
	for _ in pairs(definition.Attacks) do
		attack_count += 1
	end
	if attack_count ~= #definition.Attacks then
		return false, "attacks must be a dense array"
	end
	for attack_index, attack in ipairs(definition.Attacks) do
		local ok, reason = validate_attack(attack)
		if not ok then
			return false, ("invalid attack %d: %s"):format(attack_index, reason)
		end
	end
	local ok, reason = validate_charge(definition.Charge)
	if not ok then
		return false, ("invalid charge definition: %s"):format(reason)
	end
	return true
end

function Validator.validate_combat_config(config)
	if typeof(config) ~= "table" then
		return false, "config must be a table"
	end
	if not is_non_negative(config.TimingTolerance) then
		return false, "invalid TimingTolerance"
	end
	if not is_positive(config.PendingAttackTimeout) then
		return false, "invalid PendingAttackTimeout"
	end
	return true
end

return Validator
