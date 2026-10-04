-- Server-side validation of one reported hit. Returns (humanoid, nil, rewound)
-- when the hit is plausible and (nil, reason) otherwise, with reason a
-- RejectReason. `rewound` is true when the hit only passed against the
-- target's lag-compensated (rewound) position.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)

local CombatValidation = {}

local MIN_FACING_DOT = Config.Combat.MinFacingDot
-- Other characters standing between attacker and target are passed through
-- (they are not cover). This bounds how many of them a single check skips.
local MAX_LINE_OF_SIGHT_CASTS = Config.Combat.MaxLineOfSightCasts
local HITPOINT_TAG = Config.World.Tags.Hitpoint
local ROOT_PART = Config.World.Names.RootPart

local function is_finite_vector3(value)
	return typeof(value) == "Vector3"
		and math.isfinite(value.X)
		and math.isfinite(value.Y)
		and math.isfinite(value.Z)
end

-- Distance from a world point to an oriented bounding box. Zero when the
-- point is inside the box.
local function distance_to_box(box_cframe, box_size, point)
	local local_point = box_cframe:PointToObjectSpace(point)
	local half_size = box_size / 2
	local clamped = Vector3.new(
		math.clamp(local_point.X, -half_size.X, half_size.X),
		math.clamp(local_point.Y, -half_size.Y, half_size.Y),
		math.clamp(local_point.Z, -half_size.Z, half_size.Z)
	)

	return (local_point - clamped).Magnitude
end

-- Casts from origin to target. Both combatants are excluded, parts with
-- CanCollide or CanQuery disabled are ignored, and other characters are
-- skipped so a bystander does not count as a wall.
local function is_line_clear(raycast_params, exclude, origin, target)
	local direction = target - origin

	for _ = 1, MAX_LINE_OF_SIGHT_CASTS do
		raycast_params.FilterDescendantsInstances = exclude

		local result = Workspace:Raycast(origin, direction, raycast_params)
		if not result then
			return true
		end

		local bystander = CharacterQuery.resolve(result.Instance)
		if not bystander then
			return false
		end

		table.insert(exclude, bystander)
	end

	return false
end

local function is_valid_active(active)
	return typeof(active) == "table"
		and typeof(active.Character) == "Instance"
		and active.Character:IsA("Model")
		and typeof(active.Wielded) == "Instance"
		and active.Wielded:IsA("BasePart")
		and typeof(active.Move) == "table"
		and typeof(active.Move.Hitbox) == "string"
end

-- Reach (target root within weapon range of the attacker) and body (the
-- reported impact on or near the target's bounding box) checks.
local function check_reach_and_body(attacker_position, target_position, box_cframe, box_size, hit_position, range, tolerance)
	if (target_position - attacker_position).Magnitude > range + tolerance then
		return RejectReason.Reach
	end

	-- The reported impact must be on (or, allowing for replication lag, close
	-- to) the target's body, not merely somewhere within weapon range of it.
	if distance_to_box(box_cframe, box_size, hit_position) > tolerance then
		return RejectReason.OffBody
	end

	return nil
end

function CombatValidation.ValidateHit(
	weapon_service,
	player,
	active,
	hit_character,
	segment_instance,
	hit_position,
	opts
)
	if typeof(hit_character) ~= "Instance" or not hit_character:IsA("Model") then
		return nil, RejectReason.BadPayload
	end

	-- Hit packets are only meaningful when they include both the authored
	-- hitpoint attachment and the world-space impact position. These fields are
	-- required so the server can perform all spatial checks below.
	if typeof(segment_instance) ~= "Instance" or not segment_instance:IsA("Attachment") then
		return nil, RejectReason.BadPayload
	end

	if not is_finite_vector3(hit_position) then
		return nil, RejectReason.BadPayload
	end

	if not is_valid_active(active) then
		return nil, RejectReason.BadPayload
	end

	if hit_character == active.Character or not hit_character:IsDescendantOf(Workspace) then
		return nil, RejectReason.TargetInvalid
	end

	-- The client reports the resolved character, never a model nested inside
	-- one (such as a held weapon).
	if CharacterQuery.resolve(hit_character) ~= hit_character then
		return nil, RejectReason.TargetInvalid
	end

	local wielded = weapon_service:GetWielded(player, active.Move.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		return nil, RejectReason.WieldMismatch
	end

	if not segment_instance:IsDescendantOf(active.Wielded) then
		return nil, RejectReason.NoHitpoint
	end

	if not CollectionService:HasTag(segment_instance, HITPOINT_TAG) then
		return nil, RejectReason.NoHitpoint
	end

	local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
	local hit_root = hit_character:FindFirstChild(ROOT_PART)
	local attacker_root = active.Character:FindFirstChild(ROOT_PART)

	if not CharacterQuery.is_alive(hit_humanoid)
		or not hit_root
		or not hit_root:IsA("BasePart")
		or not attacker_root
		or not attacker_root:IsA("BasePart") then
		return nil, RejectReason.TargetInvalid
	end

	local range = active.Move.Range
	local hit_position_tolerance = active.Move.HitPositionTolerance

	if typeof(range) ~= "number"
		or not math.isfinite(range)
		or range <= 0
		or typeof(hit_position_tolerance) ~= "number"
		or not math.isfinite(hit_position_tolerance)
		or hit_position_tolerance < 0 then
		return nil, RejectReason.BadPayload
	end

	local box_cframe, box_size = hit_character:GetBoundingBox()
	local reason = check_reach_and_body(
		attacker_root.Position,
		hit_root.Position,
		box_cframe,
		box_size,
		hit_position,
		range,
		hit_position_tolerance
	)

	-- Lag compensation: the attacker saw the target up to Rewind seconds in
	-- the past. Reach and body are retried against the target's recorded
	-- state then (the attacker keeps its current position). This only makes
	-- validation more lenient; every other check still runs.
	local rewound = false
	local target_offset = Vector3.zero
	local history = opts and opts.History
	if reason and history then
		local latest = history:Latest(hit_character)
		local sample = latest and history:Sample(hit_character, latest.Time - opts.Rewind)
		if sample then
			local sample_root = sample.RootCFrame.Position
			if not check_reach_and_body(
				attacker_root.Position,
				sample_root,
				sample.BoxCFrame,
				sample.BoxSize,
				hit_position,
				range,
				hit_position_tolerance
			) then
				reason = nil
				rewound = true
				target_offset = sample_root - hit_root.Position
			end
		end
	end

	if reason then
		return nil, reason
	end

	-- The impact must also be where the weapon's hitpoint actually is.
	if (segment_instance.WorldPosition - hit_position).Magnitude > hit_position_tolerance then
		return nil, RejectReason.HitpointOffset
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
			return nil, RejectReason.Facing
		end
	end

	local raycast_params = active.ValidationRaycastParams
	if typeof(raycast_params) ~= "RaycastParams" then
		return nil, RejectReason.BadPayload
	end

	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.IgnoreWater = true
	raycast_params.RespectCanCollide = true

	-- Line of sight is checked from the attacker's body to the target's body,
	-- never skipped. Root-to-root and head-to-head are tried so a waist-high
	-- ledge or an overhang alone does not block a legitimate swing; a wall
	-- blocks both.
	-- After a rewind, line of sight runs to where the target was.
	if is_line_clear(
		raycast_params,
		{ active.Character, hit_character },
		attacker_root.Position,
		hit_root.Position + target_offset
	) then
		return hit_humanoid, nil, rewound
	end

	local attacker_head = active.Character:FindFirstChild("Head")
	local hit_head = hit_character:FindFirstChild("Head")
	if attacker_head
		and hit_head
		and attacker_head:IsA("BasePart")
		and hit_head:IsA("BasePart")
		and is_line_clear(
			raycast_params,
			{ active.Character, hit_character },
			attacker_head.Position,
			hit_head.Position + target_offset
		) then
		return hit_humanoid, nil, rewound
	end

	return nil, RejectReason.NoLOS
end

return CombatValidation
