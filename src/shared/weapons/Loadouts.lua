--!strict
-- Named starting loadouts: slot number -> weapon id. Validated by Catalog
-- (equippable ids only, never Catalog.DefaultId, slots 1..Inventory.MaxSlots)
-- and by ItemCatalog (every weapon must have an item). A new profile is
-- seeded once from Starter, each weapon becoming its item.
return {
	Starter = { [2] = "Katana" },
}
