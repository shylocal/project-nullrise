local Fists = {}

Fists.Type = "Melee"
Fists.Model = "Fists"
Fists.CanSprintWhileAttacking = true

Fists.Wield = {
	RightFist = "Right Arm",
	LeftFist = "Left Arm",
}

Fists.Animations = {
	Equip = {
		Id = "rbxassetid://13012702135",
		Priority = Enum.AnimationPriority.Action,
		Looped = false,
	},

	Idle = {
		Id = "rbxassetid://13012725349",
		Priority = Enum.AnimationPriority.Idle,
		Looped = true,
	},

	Sprint = {
		Id = "rbxassetid://13206474077",
		Priority = Enum.AnimationPriority.Movement,
		Looped = true,

		TransitionTime = 0.325,
	},

	Charge = {
		Id = "rbxassetid://13013063082",
		Priority = Enum.AnimationPriority.Action,
		Looped = false,

		TransitionTime = 0.275,
	},
}

Fists.Attacks = {
	[1] = {
		Animation = {
			Id = "rbxassetid://13012786136",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Hitbox = "RightFist",
		Damage = 10,
		Cooldown = 0.3,
		MinDuration = 0.3,
		HitStartAt = 0.1,
		HitWindow = 0.55,
		HitPositionTolerance = 3,
		Range = 8,
	},

	[2] = {
		Animation = {
			Id = "rbxassetid://13012922268",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Hitbox = "LeftFist",
		Damage = 10,
		Cooldown = 0.3,
		MinDuration = 0.3,
		HitStartAt = 0.1,
		HitWindow = 0.55,
		HitPositionTolerance = 3,
		Range = 8,
	},
}

Fists.Charge = {
	Animation = Fists.Animations.Charge,
	Hitbox = "RightFist",
	Damage = 20,
	Cooldown = 0.6,
	MinDuration = 0.6,
	-- Measured from the charge start. The charge pauses on its HitStart
	-- marker while held and is released automatically at MaxHoldTime.
	HitStartAt = 0.15,
	MaxHoldTime = 10,
	-- Charge hits stay valid for HitWindow after the release (HitStart).
	HitWindow = 0.55,
	HitPositionTolerance = 3,
	Range = 8,
	-- How long the primary input must be held before it becomes a charge.
	HoldTime = 0.15,
}

return Fists
