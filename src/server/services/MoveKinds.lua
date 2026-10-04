--!strict
-- Server timing rules per move kind. All times are on the server clock; the
-- tolerance only absorbs jitter between two packets sent by the same client.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.shared.weapons.Types)

export type Timing = { HitStartOpensAt: number, HitStartClosesAt: number, ExpiresAt: number }

export type ActiveTiming = { ExpiresAt: number }

export type MoveKind = {
	-- The HitStart window and the move's lifetime, from its start.
	create_timing: (move: Types.MoveDef, started_at: number, tolerance: number) -> Timing,
	-- When hits stop being accepted, given the HitStart arrived at `now`.
	hit_expires_at: (move: Types.MoveDef, active: ActiveTiming, now: number, tolerance: number) -> number,
}

local function hit_start_opens_at(move: Types.MoveDef, started_at: number, tolerance: number): number
	return started_at + move.HitStartAt - tolerance
end

-- A light move's hits must land within HitWindow of its HitStart marker.
local Light: MoveKind = {
	create_timing = function(move, started_at, tolerance)
		local closes_at = started_at + move.HitStartAt + move.HitWindow + tolerance
		return {
			HitStartOpensAt = hit_start_opens_at(move, started_at, tolerance),
			HitStartClosesAt = closes_at,
			ExpiresAt = closes_at,
		}
	end,
	hit_expires_at = function(_move, active, _now, _tolerance)
		return active.ExpiresAt
	end,
}

-- A charge may be held until Hold.MaxHoldTime, and its hit window starts when
-- it is released (HitStart), so its lifetime extends past the longest hold.
local Charge: MoveKind = {
	create_timing = function(move, started_at, tolerance)
		local hold = move.Hold :: Types.HoldDef
		local closes_at = started_at + hold.MaxHoldTime + tolerance
		return {
			HitStartOpensAt = hit_start_opens_at(move, started_at, tolerance),
			HitStartClosesAt = closes_at,
			ExpiresAt = closes_at + move.HitWindow,
		}
	end,
	hit_expires_at = function(move, active, now, tolerance)
		return math.min(active.ExpiresAt, now + move.HitWindow + tolerance)
	end,
}

local MoveKinds: { [string]: MoveKind } = {
	Light = Light,
	Charge = Charge,
}

return table.freeze(MoveKinds)
