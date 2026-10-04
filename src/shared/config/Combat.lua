--!strict
-- Combat network and validation tuning. Per-attack timing lives on the weapon
-- definitions; these values cover transport, anti-abuse and (from Phase 2)
-- damage policy.
local Combat = {
	-- Seconds of network jitter the server tolerates when comparing the arrival
	-- time of two packets from the same client (Attack -> HitStart, etc.).
	TimingTolerance = 0.1,
	-- Seconds the client waits for AttackAccepted/AttackRejected before it
	-- gives up on a pending attack and allows new input again.
	PendingAttackTimeout = 1,
	-- Most distinct targets one attack may damage.
	MaxHitsPerAttack = 8,
	-- Most Hit packets one attack may send (accepted or not).
	MaxHitRequestsPerAttack = 12,
	-- Failed validations against one target before its packets are ignored.
	MaxRejectsPerTarget = 2,
	-- Minimum dot between the attacker's look vector and the direction to the target.
	MinFacingDot = -0.25,
	MaxLineOfSightCasts = 4,
	-- Minimum seconds between throttled AttackRejected replies to one player.
	RejectReplyInterval = 0.25,
	LagCompensation = {
		Enabled = true,
		InterpolationDelay = 0.1,
		MaxRewind = 0.3,
		HistoryCapacity = 64,
	},
	Damage = {
		FriendlyFire = false,
		SpawnProtectionSeconds = 0,
		RecentAttackerWindow = 15,
		RecentAttackerCount = 5,
		AllowUntaggedHumanoidTargets = true,
	},
	Fx = {
		RelevanceRadius = 120,
	},
}

export type CombatConfig = typeof(Combat)

return Combat
