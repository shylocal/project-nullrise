local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local CombatValidation = {}

local HIT_DISTANCE_MARGIN = 4

local function is_finite_vector3(value)
	return typeof(value) == "Vector3"
		and math.isfinite(value.X)
		and math.isfinite(value.Y)
		and math.isfinite(value.Z)
end

function CombatValidation.ValidateHit(
	weapon_service,
	player,
	active,
	hit_character,
	segment_instance,
	hit_position
)
	if typeof(hit_character) ~= "Instance" or not hit_character:IsA("Model") then
		return nil
	end

	if segment_instance ~= nil then
		if typeof(segment_instance) ~= "Instance" or not segment_instance:IsA("Attachment") then
			return nil
		end
	end

	if hit_position ~= nil and not is_finite_vector3(hit_position) then
		return nil
	end

	if hit_character == active.Character or not hit_character:IsDescendantOf(Workspace) then
		return nil
	end

	local wielded = weapon_service:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		return nil
	end

	if segment_instance then
		if not segment_instance:IsDescendantOf(active.Wielded) then
			return nil
		end

		if not CollectionService:HasTag(segment_instance, "Hitpoint") then
			return nil
		end
	end

	local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
	local hit_root = hit_character:FindFirstChild("HumanoidRootPart")
	local attacker_root = active.Character:FindFirstChild("HumanoidRootPart")

	if not hit_humanoid or hit_humanoid.Health <= 0 or not hit_root or not attacker_root then
		return nil
	end

	local range = active.Attack.Range or 8
	local network_tolerance = active.Attack.NetworkTolerance or HIT_DISTANCE_MARGIN

	if typeof(range) ~= "number"
		or not math.isfinite(range)
		or range <= 0
		or typeof(network_tolerance) ~= "number"
		or not math.isfinite(network_tolerance)
		or network_tolerance < 0 then
		return nil
	end

	local max_distance = range + network_tolerance

	if (hit_root.Position - attacker_root.Position).Magnitude > max_distance then
		return nil
	end

	if hit_position and (hit_root.Position - hit_position).Magnitude > max_distance then
		return nil
	end

	if segment_instance and hit_position
		and (segment_instance.WorldPosition - hit_position).Magnitude > network_tolerance then
		return nil
	end

	if hit_position then
		local raycast_params = RaycastParams.new()
		raycast_params.FilterType = Enum.RaycastFilterType.Exclude
		raycast_params.FilterDescendantsInstances = {active.Character}

		local origin = segment_instance and segment_instance.WorldPosition or attacker_root.Position
		local direction = hit_position - origin

		if direction.Magnitude > 0 then
			local result = Workspace:Raycast(origin, direction, raycast_params)

			if result and not result.Instance:IsDescendantOf(hit_character) then
				return nil
			end
		end
	end

	return hit_humanoid
end

return CombatValidation
