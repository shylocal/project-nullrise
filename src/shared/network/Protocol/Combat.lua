--!strict
-- Actions on the Combat RemoteEvent (both directions). Every attack payload
-- key is a move id (Catalog move ids, per weapon).
return table.freeze({
	Attack = "Attack",
	AttackAccepted = "AttackAccepted",
	AttackRejected = "AttackRejected",
	HitStart = "HitStart",
	Hit = "Hit",
	HitConfirmed = "HitConfirmed",
	HitStop = "HitStop",
})
