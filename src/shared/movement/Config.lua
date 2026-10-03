-- Shared movement tuning. Runtime progression modifiers should be applied
-- through MovementController rather than mutating these project defaults.
return {
	WalkSpeed = 16,
	SprintSpeed = 24,
	-- Minimum Humanoid.MoveDirection magnitude that counts as moving. Holding
	-- Sprint below this (standing still) neither sprints nor enables a vault.
	SprintMinMoveMagnitude = 0.1,
}
