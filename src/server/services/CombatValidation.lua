local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local CombatValidation = {}

local HIT_DISTANCE_MARGIN = 4
local MIN_FACING_DOT = -0.25

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

	-- Hit packets are only meaningful when they include both the authored
	-- hitpoint attachment and the world-space impact position. These fields are
	-- required so the server can perform all spatial checks below.
	if typeof(segment_instance) ~= "Instance" or not segment_instance:IsA("Attachment") then
		return nil
	end

	if not is_finite_vector3(hit_position) then
		return nil
	end

	if typeof(active) ~= "table"
		or typeof(active.Character) ~= "Instance"
		or not active.Character:IsA("Model")
		or typeof(active.Wielded) ~= "Instance"
		or not active.Wielded:IsA("BasePart")
		or typeof(active.Attack) ~= "table"
		or typeof(active.Attack.Hitbox) ~= "string" then
		return nil
	end

	if hit_character == active.Character or not hit_character:IsDescendantOf(Workspace) then
		return nil
	end

	local wielded = weapon_service:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		return nil
	end

	if not segment_instance:IsDescendantOf(active.Wielded) then
		return nil
	end

	if not CollectionService:HasTag(segment_instance, "Hitpoint") then
		return nil
	end

	local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
	local hit_root = hit_character:FindFirstChild("HumanoidRootPart")
	local attacker_root = active.Character:FindFirstChild("HumanoidRootPart")

	if not hit_humanoid or hit_humanoid.Health <= 0 or not hit_root or not attacker_root then
		return nil
	end

	local range = active.Attack.Range or 8
	local network_tolerance = active.Attack.HitPositionTolerance or HIT_DISTANCE_MARGIN

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

	if (hit_root.Position - hit_position).Magnitude > max_distance then
		return nil
	end

	if (segment_instance.WorldPosition - hit_position).Magnitude > network_tolerance then
		return nil
	end

	local horizontal_look = Vector3.new(
		attacker_root.CFrame.LookVector.X,
		0,
		attacker_root.CFrame.LookVector.Z
	)
	local horizontal_target = Vector3.new(
		hit_position.X - attacker_root.Position.X,
		0,
		hit_position.Z - attacker_root.Position.Z
	)

	if horizontal_look.Magnitude > 0.05 and horizontal_target.Magnitude > 0.05 then
		local facing_dot = horizontal_look.Unit:Dot(horizontal_target.Unit)
		if facing_dot < MIN_FACING_DOT then
			return nil
		end
	end

	local raycast_params = active.ValidationRaycastParams
	if typeof(raycast_params) ~= "RaycastParams" then
		return nil
	end

	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = { active.Character, hit_character }
	raycast_params.IgnoreWater = true

	local origin = segment_instance.WorldPosition
	local direction = hit_position - origin

	if direction.Magnitude > 0 then
		local result = Workspace:Raycast(origin, direction, raycast_params)
		if result then
			return nil
		end
	end

	return hit_humanoid
end

return CombatValidation
