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
}

-- Shared by every move unless the move sets its own value.
Katana.MoveDefaults = {
	Hitbox = "Mesh",
	HitWindow = 0.55,
	HitPositionTolerance = 3,
	Range = 10,
}

Katana.Moves = {
	Light1 = {
		Kind = "Light",
		Animation = {
			Id = "rbxassetid://14148902740",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Damage = 15,
		Cooldown = 0.35,
		MinDuration = 0.35,
		HitStartAt = 0.1,
	},

	Light2 = {
		Kind = "Light",
		Animation = {
			Id = "rbxassetid://14148910201",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Damage = 15,
		Cooldown = 0.35,
		MinDuration = 0.35,
		HitStartAt = 0.1,
	},

	Heavy = {
		Kind = "Charge",
		Animation = {
			Id = "rbxassetid://14148935586",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,

			TransitionTime = 0.275,
		},

		Damage = 30,
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

Katana.Combo = { "Light1", "Light2" }

Katana.Bindings = {
	Primary = { Tap = "Combo", Hold = "Heavy" },
}

return Katana
