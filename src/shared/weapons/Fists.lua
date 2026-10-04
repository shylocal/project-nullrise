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
}

-- Shared by every move unless the move sets its own value.
Fists.MoveDefaults = {
	HitWindow = 0.55,
	HitPositionTolerance = 3,
	Range = 8,
}

Fists.Moves = {
	Light1 = {
		Kind = "Light",
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
	},

	Light2 = {
		Kind = "Light",
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
	},

	Heavy = {
		Kind = "Charge",
		Animation = {
			Id = "rbxassetid://13013063082",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,

			TransitionTime = 0.275,
		},

		Hitbox = "RightFist",
		Damage = 20,
		Cooldown = 0.6,
		MinDuration = 0.6,
		-- Measured from the move start. The move pauses on its HitStart
		-- marker while held; its hits stay valid for HitWindow after the release.
		HitStartAt = 0.15,
		Hold = {
			HoldTime = 0.15,
			MaxHoldTime = 10,
		},
	},
}

Fists.Combo = { "Light1", "Light2" }

Fists.Bindings = {
	Primary = { Tap = "Combo", Hold = "Heavy" },
}

return Fists
