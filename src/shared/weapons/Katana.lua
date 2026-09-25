local Katana = {}

Katana.Type = "Melee"
Katana.MeleeType = "Sharp"
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
		Cooldown = 0.1,
		NetworkTolerance = 3,
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
		Cooldown = 0.1,
		NetworkTolerance = 3,
		Range = 10,
	},
}

Katana.Charge = {
	Animation = Katana.Animations.Charge,
	Hitbox = "Mesh",
	Damage = 30,
	Cooldown = 0.1,
	NetworkTolerance = 3,
	Range = 10,
	HoldTime = 0.15,
}

return Katana
