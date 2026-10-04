local Katana = {}

Katana.Type = "Melee"
Katana.Model = "Katana"
Katana.CanSprintWhileAttacking = true

Katana.Wield = {
	Handle = "Right Arm",
}

Katana.Animations = {
	Equip = {
		Id = "rbxassetid://14148916157",
		Priority = Enum.AnimationPriority.Action,
		Looped = false,
	},

	Idle = {
		Id = "rbxassetid://14149034454",
		Priority = Enum.AnimationPriority.Idle,
		Looped = true,
	},

	Sprint = {
		Id = "rbxassetid://14149034454",
		Priority = Enum.AnimationPriority.Movement,
		Looped = true,
		-- Intentionally reuses the Idle animation.
		SharedWith = "Idle",

		TransitionTime = 0.325,
	},

	Charge = {
		Id = "rbxassetid://14148935586",
		Priority = Enum.AnimationPriority.Action,
		Looped = false,

		TransitionTime = 0.275,
	},
}

Katana.Attacks = {
	[1] = {
		Animation = {
			Id = "rbxassetid://14148902740",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Hitbox = "Mesh",
		Damage = 15,
		Cooldown = 0.35,
		MinDuration = 0.35,
		HitStartAt = 0.1,
		HitWindow = 0.55,
		HitPositionTolerance = 3,
		Range = 10,
	},

	[2] = {
		Animation = {
			Id = "rbxassetid://14148910201",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Hitbox = "Mesh",
		Damage = 15,
		Cooldown = 0.35,
		MinDuration = 0.35,
		HitStartAt = 0.1,
		HitWindow = 0.55,
		HitPositionTolerance = 3,
		Range = 10,
	},
}

Katana.Charge = {
	Animation = Katana.Animations.Charge,
	Hitbox = "Mesh",
	Damage = 30,
	Cooldown = 0.6,
	MinDuration = 0.6,
	-- Measured from the charge start. The charge pauses on its HitStart
	-- marker while held and is released automatically at MaxHoldTime.
	HitStartAt = 0.15,
	MaxHoldTime = 10,
	-- Charge hits stay valid for HitWindow after the release (HitStart).
	HitWindow = 0.55,
	HitPositionTolerance = 3,
	Range = 10,
	-- How long the primary input must be held before it becomes a charge.
	HoldTime = 0.15,
}

return Katana
