local Fists = {}

Fists.Type = "Melee"
Fists.MeleeType = "Blunt"
Fists.Model = "Fists"

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
		Cooldown = 0.35,
		HitboxDuration = 0.15,
	},

	[2] = {
		Animation = {
			Id = "rbxassetid://13012922268",
			Priority = Enum.AnimationPriority.Action,
			Looped = false,
		},

		Hitbox = "LeftFist",
		Damage = 10,
		Cooldown = 0.35,
		HitboxDuration = 0.15,
	},
}

return Fists
