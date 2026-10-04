--!strict
-- Names of things that live in the place file: CollectionService tags,
-- collision groups, instance names, folders and attributes. Code must read
-- these from here rather than repeating the literals.
local World = {
	Tags = {
		Climbable = "Climbable",
		-- Must equal packages.ShapecastHitbox.Settings.Tag (asserted by Config.spec).
		Hitpoint = "Hitpoint",
		Damageable = "Damageable",
	},
	CollisionGroups = {
		Climbable = "Climbable",
	},
	Names = {
		HitpointAttachment = "Hitpoint",
		RootPart = "HumanoidRootPart",
	},
	Folders = {
		WeaponModels = "weapon_models",
		UiTemplates = "ui",
		Remotes = "remotes",
	},
	Attributes = {
		WeaponId = "WeaponId",
		Invulnerable = "Invulnerable",
		ParkourQueryMetrics = "ParkourQueryMetrics",
		ClimbableDynamic = "ClimbableDynamic",
	},
}

export type WorldConfig = typeof(World)

return World
