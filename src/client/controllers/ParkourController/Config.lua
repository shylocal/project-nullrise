-- Parkour tuning values. Keep traversal thresholds centralized so behavior can
-- be adjusted without editing detection, movement, and mantle algorithms.
return {
	Debug = false,
	ClimbableTag = "Climbable",
	WallReach = 3.25,
	MaxGrabHeight = 4.5,
	HangDrop = 2.35,
	WallGap = 0.8,
	TraverseSpeed = 5,
	SurfaceProbe = 1.4,
	MaxTopSurfaceHits = 16,
	MantleMaxRise = 12.5,
	GroundMantleMaxRise = 3.5,
	MantleMaxInward = 8,
	MantleMaxOutward = 2,
	MantleMaxLateral = 5,
	MantleMinRise = 0.25,
	TraverseHeightTolerance = 1.5,
	CornerLockDistance = 1.75,
}
