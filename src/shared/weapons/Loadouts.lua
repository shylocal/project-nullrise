--!strict
-- Named starting loadouts: slot number -> weapon id. Validated by Catalog
-- (equippable ids only, never Catalog.DefaultId, slots 1..Inventory.MaxSlots).
return {
	Starter = { [2] = "Katana" },
}
