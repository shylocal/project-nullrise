--!strict
-- Logical input actions shared by the input sources and the controllers.
-- Slot actions ("Slot1".."SlotN") are generated from Config.Inventory.MaxSlots.
local Config = require(script.Parent.Parent.config)

local Actions = {
	Primary = "Primary",
	Sprint = "Sprint",
	Jump = "Jump",
	Forward = "Forward",
	Backward = "Backward",
	Left = "Left",
	Right = "Right",
}

local slots: { string } = {}
local slot_indices: { [string]: number } = {}
for index = 1, Config.Inventory.MaxSlots do
	local name = "Slot" .. index
	slots[index] = name
	slot_indices[name] = index
	Actions[name] = name
end

-- Ordered slot action names, Slots[i] == "Slot" .. i.
Actions.Slots = table.freeze(slots)

-- Returns the slot number for a slot action ("Slot3" -> 3), or nil.
function Actions.slot_index(action: string): number?
	return slot_indices[action]
end

return table.freeze(Actions)
