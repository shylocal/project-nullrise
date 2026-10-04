--!strict
-- Parkour tuning (client ParkourController; the server envelope reads the
-- speeds). Keep traversal thresholds centralized so behaviour can be adjusted
-- without editing detection, movement and mantle algorithms. The climbable tag
-- and collision group live in World.
local Parkour = {
	WallReach = 4.25,
	MaxGrabHeight = 4.5,
	HangDrop = 2.35,
	WallGap = 0.8,
	TallWallMinHeight = 5,
	TallWallTopReachMargin = 0.25,
	TallWallEdgeClearance = 0.08,
	TraverseSpeed = 7,
	TraverseSprintMultiplier = 1.7,
	VaultEnabled = true,
	VaultDetectionDistance = 8,
	VaultDetectionHeight = 0.4,
	VaultMinHeight = 0.3,
	VaultMaxHeight = 4,
	VaultLandingGap = 2,
	-- Hard cap on the root-to-landing displacement of a scripted vault.
	VaultMaxOverDistance = 13.5,
	VaultTopLandingInset = 1,
	VaultLandingHeightTolerance = 1.1,
	VaultMinArcHeight = 1,
	VaultMaxArcHeight = 6.5,
	VaultObstacleClearance = 0.6,
	VaultTallObstacleClearancePerStud = 0.3,
	VaultTallDurationPerStud = 0.1,
	VaultFarSideOnlyHeight = 2.5,
	VaultLongObstacleHopLength = 20,
	VaultGroundSupportTolerance = 0.65,
	VaultMinTopHopDepth = 2.5,
	VaultTopHopHeightMargin = 0.8,
	VaultTopHopForwardBoostSpeed = 8,
	-- Seconds before an unlanded top-hop restores the native jump settings.
	VaultTopHopTimeout = 3,
	VaultPhysicalExitProgress = 0.45,
	VaultDuration = 0.42,
	VaultDurationMultiplier = 0.95,
	VaultCooldown = 0.3,
	VaultDetectionHalfWidth = 1.25,
	VaultForwardBoostSpeed = 12,
	VaultHipHeightReduction = 1,
	ClimbSmoothness = 18,
	SurfaceProbe = 1.4,
	MaxTopSurfaceHits = 16,
	MantleMaxRise = 12.5,
	GroundMantleMaxRise = 3.5,
	MantleMaxInward = 8,
	MantleMaxOutward = 2,
	MantleMaxLateral = 5,
	MantleMinRise = 0.25,
	MantleDuration = 0.35,
	TraverseHeightTolerance = 1.5,
	CornerLockDistance = 1.75,
	-- While straight A/D traversal stays valid, the corner probe fan is only
	-- re-run after the hang target moves this far from its last empty result.
	CornerProbeRecheckDistance = 0.5,
	-- Seconds an empty corner-fan result is reused while straight traversal is blocked.
	CornerProbeMissTtl = 0.2,
	-- Raycasts per frame above which Studio warns (metrics count regardless).
	FrameRayBudget = 48,
	-- Minimum seconds between frame-budget warnings.
	BudgetWarnInterval = 5,
}

export type ParkourConfig = typeof(Parkour)

return Parkour
