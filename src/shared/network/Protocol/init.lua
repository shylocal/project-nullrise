--!strict
-- Remote action names, one module per remote. Keep client and server message
-- contracts in sync through these tables; never repeat the literals.
return table.freeze({
	Combat = require(script.Combat),
	Inventory = require(script.Inventory),
	Weapon = require(script.Weapon),
	CombatFx = require(script.CombatFx),
})
