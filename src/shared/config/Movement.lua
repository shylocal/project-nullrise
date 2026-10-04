--!strict
-- Character locomotion tuning shared by the client controllers and the server
-- movement observer. Runtime progression modifiers go through
-- MovementController, never by mutating these defaults.
local Movement = {
	WalkSpeed = 16,
	SprintSpeed = 24,
	-- Minimum Humanoid.MoveDirection magnitude that counts as moving. Holding
	-- Sprint below this (standing still) neither sprints nor enables a vault.
	SprintMinMoveMagnitude = 0.1,
	-- Upper bound of native jump take-off speed; must stay >= the take-off
	-- implied by StarterPlayer.CharacterJumpPower.
	MaxJumpVelocity = 50,
	-- Server movement envelope (see config/Envelope.lua). Margins multiply the
	-- fastest legitimate source speed; the others are absolute limits.
	Envelope = {
		HorizontalMargin = 2.6,
		UpwardMargin = 4.8,
		MaxDownwardSpeed = 240,
		TeleportDistance = 40,
	},
}

export type MovementConfig = typeof(Movement)

return Movement
