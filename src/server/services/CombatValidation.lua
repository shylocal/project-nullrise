--!strict
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

local Types = require(ReplicatedStorage.shared.weapons.Types)

local PositionHistory = require(script.Parent.PositionHistory)

type Reason = RejectReason.Reason

-- The parts of an active move that validation reads (Move: Hitbox, Range
-- and HitPositionTolerance).
export type HitContext = {
	Character: Model,
	Wielded: Instance,
	Move: Types.MoveDef,
	ValidationRaycastParams: RaycastParams,
}

-- `P` identifies the attacker to the wield lookup (a Player in game).
export type WieldLookup<P> = {
	GetWielded: (self: any, player: P, wield_name: string) -> Instance?,
}

export type ValidateOptions = {
	-- Target history for lag compensation; nil disables the rewind retry.
	History: PositionHistory.PositionHistory?,
	-- Seconds before the target's newest sample to rewind to.
	Rewind: number,
	-- When set, filled with the measured distances (Studio diagnostics).
	Debug: { [string]: number }?,
}

local CombatValidation = {}

local MIN_FACING_DOT = Config.Combat.MinFacingDot
-- Other characters standing between attacker and target are passed through
-- (they are not cover). This bounds how many of them a single check skips.
local MAX_LINE_OF_SIGHT_CASTS = Config.Combat.MaxLineOfSightCasts
local HITPOINT_TAG = Config.World.Tags.Hitpoint
local ROOT_PART = Config.World.Names.RootPart

local function is_finite_vector3(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return math.isfinite(vector.X) and math.isfinite(vector.Y) and math.isfinite(vector.Z)
end

-- True when a Hit packet's arguments have the shape ValidateHit needs: the
-- reported character Model, the hitpoint Attachment and a finite impact
-- position. Says nothing about whether the hit is plausible.
function CombatValidation.IsHitPayload(hit_character: unknown, segment_instance: unknown, hit_position: unknown): boolean
	return typeof(hit_character) == "Instance"
		and (hit_character :: Instance):IsA("Model")
		and typeof(segment_instance) == "Instance"
		and (segment_instance :: Instance):IsA("Attachment")
		and is_finite_vector3(hit_position)
end

-- Distance from a world point to an oriented bounding box. Zero when the
-- point is inside the box.
local function distance_to_box(box_cframe: CFrame, box_size: Vector3, point: Vector3): number
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
local function is_line_clear(raycast_params: RaycastParams, exclude: { Instance }, origin: Vector3, target: Vector3): boolean
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

-- The context comes from server state, but is re-checked so a stale or
-- partial record fails as BadPayload instead of erroring mid-validation.
local function is_valid_active(active: HitContext): boolean
	local context: any = active
	return type(context) == "table"
		and typeof(context.Character) == "Instance"
		and context.Character:IsA("Model")
		and typeof(context.Wielded) == "Instance"
		and context.Wielded:IsA("BasePart")
		and type(context.Move) == "table"
		and type(context.Move.Hitbox) == "string"
end

-- Distance from `point` to the segment from `a` to `a + offset`.
local function distance_to_sweep(point: Vector3, a: Vector3, offset: Vector3): number
	local length_squared = offset:Dot(offset)
	if length_squared < 1e-6 then
		return (point - a).Magnitude
	end
	local t = math.clamp((point - a):Dot(offset) / length_squared, 0, 1)
	return (point - (a + offset * t)).Magnitude
end

-- Reach (target root within weapon range of the attacker) and body (the
-- reported impact on or near the target's bounding box) checks.
local function check_reach_and_body(
	attacker_position: Vector3,
	attacker_lead: Vector3,
	target_position: Vector3,
	box_cframe: CFrame,
	box_size: Vector3,
	hit_position: Vector3,
	range: number,
	tolerance: number
): Reason?
	-- Reach is measured from anywhere along the attacker's lead (see
	-- attacker_lead), so a running attacker is not judged from where the
	-- server last saw it.
	if distance_to_sweep(target_position, attacker_position, attacker_lead) > range + tolerance then
		return RejectReason.Reach
	end

	-- The reported impact must be on (or, allowing for replication lag, close
	-- to) the target's body, not merely somewhere within weapon range of it.
	if distance_to_box(box_cframe, box_size, hit_position) > tolerance then
		return RejectReason.OffBody
	end

	return nil
end

-- How far the attacker may have moved on its own client beyond the position
-- the server holds: its server-observed velocity (from PositionHistory, so a
-- client cannot claim speed it did not show) times the same lag window the
-- target is rewound by, with the speed capped at MaxAttackerSpeed.
local LEAD_SAMPLE_SPAN = 0.1
local function attacker_lead(history: PositionHistory.PositionHistory, character: Model, window: number): Vector3
	local latest = history:Latest(character)
	if latest == nil then
		return Vector3.zero
	end
	local earlier = history:Sample(character, latest.Time - LEAD_SAMPLE_SPAN)
	if earlier == nil then
		return Vector3.zero
	end
	local dt = latest.Time - earlier.Time
	if dt <= 1e-3 then
		return Vector3.zero
	end
	local velocity = (latest.RootCFrame.Position - earlier.RootCFrame.Position) / dt
	local speed = velocity.Magnitude
	if speed < 1e-3 or not math.isfinite(speed) then
		return Vector3.zero
	end
	local max_speed = Config.Combat.LagCompensation.MaxAttackerSpeed
	if speed > max_speed then
		velocity = velocity.Unit * max_speed
	end
	return velocity * window
end

-- hit_character, segment_instance and hit_position are the client's Hit
-- packet arguments, unvalidated.
function CombatValidation.ValidateHit<P>(
	weapon_service: WieldLookup<P>,
	player: P,
	active: HitContext,
	hit_character: unknown,
	segment_instance: unknown,
	hit_position: unknown,
	opts: ValidateOptions?
): (Humanoid?, Reason?, boolean?)
	-- Hit packets are only meaningful when they include both the authored
	-- hitpoint attachment and the world-space impact position. These fields are
	-- required so the server can perform all spatial checks below.
	if not CombatValidation.IsHitPayload(hit_character, segment_instance, hit_position) then
		return nil, RejectReason.BadPayload
	end
	local target = hit_character :: Model
	local segment = segment_instance :: Attachment
	local impact = hit_position :: Vector3

	if not is_valid_active(active) then
		return nil, RejectReason.BadPayload
	end

	if target == active.Character or not target:IsDescendantOf(Workspace) then
		return nil, RejectReason.TargetInvalid
	end

	-- The client reports the resolved character, never a model nested inside
	-- one (such as a held weapon).
	if CharacterQuery.resolve(target) ~= target then
		return nil, RejectReason.TargetInvalid
	end

	local wielded = weapon_service:GetWielded(player, active.Move.Hitbox)
	if wielded == nil or wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		return nil, RejectReason.WieldMismatch
	end

	if not segment:IsDescendantOf(active.Wielded) then
		return nil, RejectReason.NoHitpoint
	end

	if not CollectionService:HasTag(segment, HITPOINT_TAG) then
		return nil, RejectReason.NoHitpoint
	end

	local hit_humanoid = target:FindFirstChildOfClass("Humanoid")
	local hit_root = target:FindFirstChild(ROOT_PART)
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

	-- Weapon data is validated at load; this guards a hand-built context.
	if type(range) ~= "number"
		or not math.isfinite(range)
		or range <= 0
		or type(hit_position_tolerance) ~= "number"
		or not math.isfinite(hit_position_tolerance)
		or hit_position_tolerance < 0 then
		return nil, RejectReason.BadPayload
	end

	local history = opts and opts.History
	local lead = if history and opts then attacker_lead(history, active.Character, opts.Rewind) else Vector3.zero

	local box_cframe, box_size = target:GetBoundingBox()
	local debug = opts and opts.Debug
	if debug then
		debug.Reach = (hit_root.Position - attacker_root.Position).Magnitude
		debug.ReachWithLead = distance_to_sweep(hit_root.Position, attacker_root.Position, lead)
		debug.ReachLimit = range + hit_position_tolerance
		debug.BodyDistance = distance_to_box(box_cframe, box_size, impact)
		debug.HitpointOffset = (segment.WorldPosition - impact).Magnitude
		debug.HitpointOffsetWithLead = distance_to_sweep(impact, segment.WorldPosition, lead)
		debug.Tolerance = hit_position_tolerance
		debug.Lead = lead.Magnitude
		debug.Rewind = opts and opts.Rewind or 0
	end
	local reason = check_reach_and_body(
		attacker_root.Position,
		lead,
		hit_root.Position,
		box_cframe,
		box_size,
		impact,
		range,
		hit_position_tolerance
	)

	-- Lag compensation: the attacker saw the target up to Rewind seconds in
	-- the past. Reach and body are retried against the target's recorded
	-- state then (the attacker keeps its current position). This only makes
	-- validation more lenient; every other check still runs.
	local rewound = false
	local target_offset = Vector3.zero
	if reason and opts and history then
		local latest = history:Latest(target)
		local sample = latest and history:Sample(target, latest.Time - opts.Rewind)
		if sample then
			local sample_root = sample.RootCFrame.Position
			if not check_reach_and_body(
				attacker_root.Position,
				lead,
				sample_root,
				sample.BoxCFrame,
				sample.BoxSize,
				impact,
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

	-- The impact must also be where the weapon's hitpoint actually is, allowing
	-- for the attacker's own movement during the lag window.
	if distance_to_sweep(impact, segment.WorldPosition, lead) > hit_position_tolerance then
		return nil, RejectReason.HitpointOffset
	end

	local horizontal_look = Vector3.new(
		attacker_root.CFrame.LookVector.X,
		0,
		attacker_root.CFrame.LookVector.Z
	)
	local horizontal_target = Vector3.new(
		impact.X - attacker_root.Position.X,
		0,
		impact.Z - attacker_root.Position.Z
	)

	if horizontal_look.Magnitude > 0.05 and horizontal_target.Magnitude > 0.05 then
		local facing_dot = horizontal_look.Unit:Dot(horizontal_target.Unit)
		if debug then
			debug.FacingDot = facing_dot
		end
		if facing_dot < MIN_FACING_DOT then
			return nil, RejectReason.Facing
		end
	end

	local raycast_params = active.ValidationRaycastParams
	if typeof(raycast_params :: unknown) ~= "RaycastParams" then
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
		{ active.Character, target },
		attacker_root.Position,
		hit_root.Position + target_offset
	) then
		return hit_humanoid, nil, rewound
	end

	local attacker_head = active.Character:FindFirstChild("Head")
	local hit_head = target:FindFirstChild("Head")
	if attacker_head
		and hit_head
		and attacker_head:IsA("BasePart")
		and hit_head:IsA("BasePart")
		and is_line_clear(
			raycast_params,
			{ active.Character, target },
			attacker_head.Position,
			hit_head.Position + target_offset
		) then
		return hit_humanoid, nil, rewound
	end

	return nil, RejectReason.NoLOS
end

return CombatValidation
