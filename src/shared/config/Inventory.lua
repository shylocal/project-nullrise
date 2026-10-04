--!strict
local Inventory = {
	-- Number of hotbar slots. PC binds keys One..Nine, so this is capped at 9.
	MaxSlots = 9,
	MaxItemIdLength = 64,
	-- Seconds during which repeated equip requests collapse into the latest one.
	EquipCoalesceWindow = 0.2,
}

export type InventoryConfig = typeof(Inventory)

return Inventory
