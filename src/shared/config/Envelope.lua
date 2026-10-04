--!strict
-- Derives the server movement envelope from the tuning that actually produces
-- motion, so raising a speed in Movement or Parkour raises the limit with it.
-- Pure: callers pass the config sections and the gravity to use. Gravity is
-- sampled once by the caller; a runtime gravity change does not update limits.
local Movement = require(script.Parent.Movement)
local Parkour = require(script.Parent.Parkour)

type MovementConfig = Movement.MovementConfig
type ParkourConfig = Parkour.ParkourConfig

export type MotionSource = { Horizontal: number?, Upward: number? }
export type Limits = {
	MaxHorizontalSpeed: number,
	MaxUpwardSpeed: number,
	MaxDownwardSpeed: number,
	TeleportDistance: number,
	Sources: { [string]: MotionSource },
}

local Envelope = {}

-- Every legitimate source of character speed, in studs per second.
function Envelope.sources(movement: MovementConfig, parkour: ParkourConfig, gravity: number): { [string]: MotionSource }
	local sprint = movement.SprintSpeed
	return {
		Walk = { Horizontal = movement.WalkSpeed },
		Sprint = { Horizontal = sprint },
		-- The scripted vault covers its sprint-plus-boost exit speed in a
		-- duration scaled by VaultDurationMultiplier.
		Vault = { Horizontal = (sprint + parkour.VaultForwardBoostSpeed) / parkour.VaultDurationMultiplier },
		VaultExit = { Horizontal = sprint + parkour.VaultForwardBoostSpeed },
		TopHop = {
			Horizontal = sprint + parkour.VaultTopHopForwardBoostSpeed,
			Upward = math.sqrt(2 * gravity * (parkour.VaultMaxHeight + parkour.VaultTopHopHeightMargin)),
		},
		Traverse = { Horizontal = parkour.TraverseSpeed * parkour.TraverseSprintMultiplier },
		Mantle = {
			Horizontal = parkour.MantleMaxInward / parkour.MantleDuration,
			Upward = (parkour.MantleMaxRise + parkour.HangDrop) / parkour.MantleDuration,
		},
		Jump = { Upward = movement.MaxJumpVelocity },
	}
end

function Envelope.compute(movement: MovementConfig, parkour: ParkourConfig, gravity: number): Limits
	if type(gravity) ~= "number" or not (gravity > 0) or gravity == math.huge then
		error(("Envelope.compute: gravity must be a positive finite number, got %s"):format(tostring(gravity)), 2)
	end
	local sources = Envelope.sources(movement, parkour, gravity)
	local max_horizontal = 0
	local max_upward = 0
	for _, source in pairs(sources) do
		if source.Horizontal ~= nil then
			max_horizontal = math.max(max_horizontal, source.Horizontal)
		end
		if source.Upward ~= nil then
			max_upward = math.max(max_upward, source.Upward)
		end
	end
	local envelope = movement.Envelope
	return {
		MaxHorizontalSpeed = envelope.HorizontalMargin * max_horizontal,
		MaxUpwardSpeed = envelope.UpwardMargin * max_upward,
		MaxDownwardSpeed = envelope.MaxDownwardSpeed,
		TeleportDistance = envelope.TeleportDistance,
		Sources = sources,
	}
end

return table.freeze(Envelope)
