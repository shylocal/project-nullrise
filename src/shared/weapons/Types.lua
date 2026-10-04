--!strict
-- Phase 1 weapon definition shape (Attacks + optional Charge). Replaced by the
-- move-based schema in Phase 2.

export type AnimationDef = {
	Id: string,
	Priority: Enum.AnimationPriority,
	Looped: boolean,
	TransitionTime: number?,
	-- Required on a later role that reuses an earlier role's Id (Equip < Idle < Sprint < Charge).
	SharedWith: string?,
}

-- Timing fields are seconds from the attack start:
--   HitStartAt   earliest time the HitStart marker can be reached
--   HitWindow    how long hits stay valid after HitStartAt
--   MinDuration  earliest time the next attack may start (server enforced)
--   Cooldown     client-side input cooldown; never shorter than MinDuration
export type AttackDef = {
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
}

-- HoldTime: how long the primary input must be held before it becomes a charge.
-- MaxHoldTime: measured from the charge start; the charge is released automatically then.
export type ChargeDef = AttackDef & { HoldTime: number, MaxHoldTime: number }

export type WeaponDefinition = {
	Id: string,
	Type: "Melee",
	Model: string,
	CanSprintWhileAttacking: boolean,
	Wield: { [string]: string },
	Animations: { Equip: AnimationDef, Idle: AnimationDef, Sprint: AnimationDef, Charge: AnimationDef? },
	Attacks: { AttackDef },
	Charge: ChargeDef?,
}

return table.freeze({})
