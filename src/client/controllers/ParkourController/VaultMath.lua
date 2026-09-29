-- Pure math for the scripted vault trajectory and temporary crouch.
-- Kept separate from the controller so these curves can be reviewed and tested independently.
local VaultMath = {}

-- Shape the vertical arc so its apex aligns with the obstacle.
function VaultMath.arc_weight(linear, peak_progress)
	local peak = math.clamp(peak_progress or 0.5, 0.2, 0.92)
	if linear <= peak then
		return math.sin((linear / peak) * math.pi * 0.5)
	end
	return math.cos(((linear - peak) / (1 - peak)) * math.pi * 0.5)
end

-- Lower quickly, hold through the middle, then restore near the end.
function VaultMath.hip_height_weight(linear)
	local function smoothstep(value)
		value = math.clamp(value, 0, 1)
		return value * value * (3 - 2 * value)
	end

	local fade_in = smoothstep(linear / 0.18)
	local fade_out = smoothstep((1 - linear) / 0.22)
	return fade_in * fade_out
end

return VaultMath
