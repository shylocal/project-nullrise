-- Shared remote action names. Keep client and server message contracts in sync here.
return {
	Combat = {
		Attack = "Attack",
		AttackAccepted = "AttackAccepted",
		AttackRejected = "AttackRejected",
		Charge = "Charge",
		HitStart = "HitStart",
		Hit = "Hit",
		HitConfirmed = "HitConfirmed",
		HitStop = "HitStop",
	},
	Inventory = {
		SelectSlot = "SelectSlot",
		SelectItem = "SelectItem",
		Changed = "Changed",
	},
	Weapon = {
		Equipped = "Equipped",
	},
}
