--!strict
-- The single, validated, deep-frozen tuning tree shared by client and server.
-- Section modules return plain tables; this module validates all of them at
-- require time (collecting every error and raising once) and then freezes the
-- result, so no consumer needs defensive fallbacks for config values.
local Freeze = require(script.Parent.utility.Freeze)
local Schema = require(script.Parent.utility.Schema)

local Combat = require(script.Combat)
local Data = require(script.Data)
local Inventory = require(script.Inventory)
local Movement = require(script.Movement)
local Network = require(script.Network)
local Parkour = require(script.Parkour)
local Telemetry = require(script.Telemetry)
local World = require(script.World)

export type MovementConfig = Movement.MovementConfig
export type ParkourConfig = Parkour.ParkourConfig
export type CombatConfig = Combat.CombatConfig
export type InventoryConfig = Inventory.InventoryConfig
export type WorldConfig = World.WorldConfig
export type NetworkConfig = Network.NetworkConfig
export type DataConfig = Data.DataConfig
export type TelemetryConfig = Telemetry.TelemetryConfig

export type Config = {
	Movement: MovementConfig,
	Parkour: ParkourConfig,
	Combat: CombatConfig,
	Inventory: InventoryConfig,
	World: WorldConfig,
	Network: NetworkConfig,
	Data: DataConfig,
	Telemetry: TelemetryConfig,
	validate: (sections: any) -> { string },
}

local positive = Schema.number({ gt = 0 })
local non_negative = Schema.number({ gte = 0 })
local positive_integer = Schema.number({ gt = 0, integer = true })
local non_empty_string = Schema.string({ nonEmpty = true })

local MOVEMENT = Schema.record({
	WalkSpeed = positive,
	SprintSpeed = positive,
	SprintMinMoveMagnitude = non_negative,
	MaxJumpVelocity = positive,
	Envelope = Schema.record({
		-- Margins below 1 would flag legitimate movement.
		HorizontalMargin = Schema.number({ gte = 1 }),
		UpwardMargin = Schema.number({ gte = 1 }),
		MaxDownwardSpeed = positive,
		TeleportDistance = positive,
	}),
})

-- Every Parkour value is a finite, non-negative number except the ones
-- overridden here.
local PARKOUR_OVERRIDES: { [string]: Schema.Spec } = {
	VaultEnabled = Schema.boolean(),
	VaultDurationMultiplier = Schema.number({ gte = 0.5, lte = 1.5 }),
	MaxTopSurfaceHits = positive_integer,
	FrameRayBudget = positive_integer,
}

local function parkour_spec(): Schema.Spec
	local fields: { [string]: Schema.Spec } = {}
	for key in pairs(Parkour) do
		fields[key] = PARKOUR_OVERRIDES[key] or non_negative
	end
	return Schema.record(fields)
end

local PARKOUR = parkour_spec()

local COMBAT = Schema.record({
	TimingTolerance = non_negative,
	PendingAttackTimeout = positive,
	MaxHitsPerAttack = positive_integer,
	MaxHitRequestsPerAttack = positive_integer,
	MaxRejectsPerTarget = positive_integer,
	MinFacingDot = Schema.number({ gte = -1, lte = 1 }),
	MaxLineOfSightCasts = positive_integer,
	RejectReplyInterval = non_negative,
	LagCompensation = Schema.record({
		Enabled = Schema.boolean(),
		InterpolationDelay = non_negative,
		MaxRewind = non_negative,
		HistoryCapacity = positive_integer,
	}),
	Damage = Schema.record({
		FriendlyFire = Schema.boolean(),
		SpawnProtectionSeconds = non_negative,
		RecentAttackerWindow = non_negative,
		RecentAttackerCount = positive_integer,
		AllowUntaggedHumanoidTargets = Schema.boolean(),
	}),
	Fx = Schema.record({
		RelevanceRadius = positive,
	}),
})

local INVENTORY = Schema.record({
	-- PC hotkeys are One..Nine.
	MaxSlots = Schema.number({ gte = 1, lte = 9, integer = true }),
	MaxItemIdLength = positive_integer,
	EquipCoalesceWindow = non_negative,
})

local WORLD = Schema.record({
	Tags = Schema.record({ Climbable = non_empty_string, Hitpoint = non_empty_string, Damageable = non_empty_string }),
	CollisionGroups = Schema.record({ Climbable = non_empty_string }),
	Names = Schema.record({ HitpointAttachment = non_empty_string, RootPart = non_empty_string }),
	Folders = Schema.record({
		WeaponModels = non_empty_string,
		UiTemplates = non_empty_string,
		Remotes = non_empty_string,
	}),
	Attributes = Schema.record({
		WeaponId = non_empty_string,
		Invulnerable = non_empty_string,
		ParkourQueryMetrics = non_empty_string,
		ClimbableDynamic = non_empty_string,
	}),
})

local RATE = Schema.record({
	Rate = positive,
	-- A bucket must hold at least one token or the action could never pass.
	Burst = Schema.number({ gte = 1 }),
})

local NETWORK = Schema.record({
	RemoteBudget = Schema.record({
		Global = RATE,
		Actions = Schema.map(Schema.string({ pattern = "^%a+%.%a+$" }), RATE, { nonEmpty = true }),
	}),
})

local DATA = Schema.record({
	StoreName = non_empty_string,
	KeyPrefix = non_empty_string,
	UseMockInStudio = Schema.boolean(),
})

local TELEMETRY = Schema.record({
	FlushInterval = positive,
	HalfLife = positive,
	DefaultWeight = non_negative,
	Weights = Schema.map(non_empty_string, non_negative),
})

local SECTIONS = Schema.record({
	Movement = MOVEMENT,
	Parkour = PARKOUR,
	Combat = COMBAT,
	Inventory = INVENTORY,
	World = WORLD,
	Network = NETWORK,
	Data = DATA,
	Telemetry = TELEMETRY,
})

local function is_number(value: any): boolean
	return type(value) == "number" and value == value
end

-- Rules spanning several fields. Each runs only when its inputs passed the
-- per-field checks well enough to compare, so a type error is not reported twice.
local function check_cross_fields(sections: any, errors: { string })
	local parkour = type(sections.Parkour) == "table" and sections.Parkour or nil
	if
		parkour
		and is_number(parkour.CornerProbeRecheckDistance)
		and is_number(parkour.CornerLockDistance)
		and not (parkour.CornerProbeRecheckDistance < parkour.CornerLockDistance)
	then
		-- A recheck distance at or beyond the corner lock would let straight
		-- traversal carry the hang past a corner before the fan re-runs.
		table.insert(errors, "Parkour.CornerProbeRecheckDistance: must be < Parkour.CornerLockDistance")
	end

	local combat = type(sections.Combat) == "table" and sections.Combat or nil
	if
		combat
		and is_number(combat.MaxHitRequestsPerAttack)
		and is_number(combat.MaxHitsPerAttack)
		and not (combat.MaxHitRequestsPerAttack >= combat.MaxHitsPerAttack)
	then
		table.insert(errors, "Combat.MaxHitRequestsPerAttack: must be >= Combat.MaxHitsPerAttack")
	end
end

-- Pure: validates a sections table shaped like the config (without
-- `validate`) and returns every error. Specs call it with broken copies.
local function validate(sections: any): { string }
	local errors = Schema.check(sections, SECTIONS, "")
	if type(sections) == "table" then
		check_cross_fields(sections, errors)
	end
	return errors
end

local sections = {
	Movement = Movement,
	Parkour = Parkour,
	Combat = Combat,
	Inventory = Inventory,
	World = World,
	Network = Network,
	Data = Data,
	Telemetry = Telemetry,
}

local errors = validate(sections)
if #errors > 0 then
	error("Invalid config:\n" .. table.concat(errors, "\n"), 0)
end

local Config: Config = {
	Movement = Movement,
	Parkour = Parkour,
	Combat = Combat,
	Inventory = Inventory,
	World = World,
	Network = Network,
	Data = Data,
	Telemetry = Telemetry,
	validate = validate,
}

return Freeze.deep(Config)
