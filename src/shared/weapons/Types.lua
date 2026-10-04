--!strict
-- Weapon definition shape (schema v2): named moves, a light-attack combo and
-- input bindings. Exports only.

export type AnimationDef = {
	Id: string,
	Priority: Enum.AnimationPriority,
	Looped: boolean,
	TransitionTime: number?,
	-- Required on a later role that reuses an earlier role's Id (Equip < Idle < Sprint).
	SharedWith: string?,
}

-- "Light" moves hit within HitWindow of their HitStart marker. "Charge" moves
-- may be held (pausing on the HitStart marker) until Hold.MaxHoldTime, and
-- their hit window starts at the release.
export type MoveKind = "Light" | "Charge"

-- HoldTime: how long the primary input must be held before it becomes this move.
-- MaxHoldTime: measured from the move start; the move is released automatically then.
export type HoldDef = { HoldTime: number, MaxHoldTime: number }

-- Timing fields are seconds from the move start:
--   HitStartAt   earliest time the HitStart marker can be reached
--   HitWindow    how long hits stay valid after HitStartAt (Light) or the release (Charge)
--   MinDuration  earliest time the next move may start (server enforced)
--   Cooldown     client-side input cooldown; never shorter than MinDuration
-- Name and Id are injected by the Catalog (Id: per weapon, sorted by name from 1).
export type MoveDef = {
	Name: string,
	Id: number,
	Kind: MoveKind,
	Animation: AnimationDef,
	Hitbox: string,
	Damage: number,
	Cooldown: number,
	MinDuration: number,
	HitStartAt: number,
	HitWindow: number,
	HitPositionTolerance: number,
	Range: number,
	CanSprintWhileAttacking: boolean?,
	Hold: HoldDef?,
}

-- Tap: "Combo" (cycle through Combo) or a move name. Hold: a Charge move name.
export type PrimaryBinding = { Tap: string, Hold: string? }

export type WeaponDefinition = {
	Id: string,
	Type: "Melee",
	Model: string,
	CanSprintWhileAttacking: boolean,
	Wield: { [string]: string },
	Animations: { Equip: AnimationDef, Idle: AnimationDef, Sprint: AnimationDef },
	MoveDefaults: { [string]: any }?,
	Moves: { [string]: MoveDef },
	Combo: { string },
	Bindings: { Primary: PrimaryBinding },
}

return table.freeze({})
