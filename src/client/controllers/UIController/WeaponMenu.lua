local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)

-- Display-only mirror of the session LoadoutClient. Button presses only
-- request a selection and never change the display directly.
local WeaponMenu = {}
WeaponMenu.__index = WeaponMenu

function WeaponMenu.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		Loadout = ui_controller.Loadout,
		Gui = nil,
		Buttons = {},
		SelectedWeapon = nil,
	}, WeaponMenu)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function WeaponMenu:_start()
	-- A missing template leaves Buttons empty, which makes every method a no-op.
	local gui = self.UIController:CloneTemplate("WeaponMenu")
	if not gui then
		return
	end

	self.Gui = gui
	self.Trove:Add(gui)
	self.Trove:Connect(gui.Destroying, function()
		if self.Gui == gui then
			self.Gui = nil
			table.clear(self.Buttons)
		end
	end)

	for _, descendant in gui:GetDescendants() do
		if not descendant:IsA("GuiButton") then
			continue
		end

		local weapon_id = descendant:GetAttribute("WeaponId")
		if typeof(weapon_id) ~= "string" then
			continue
		end

		if not Catalog.IsEquippable(Catalog.Get(weapon_id)) then
			continue
		end

		self.Buttons[weapon_id] = descendant

		-- The default weapon selects no slot; any other weapon selects the
		-- first slot whose item grants it.
		self.Trove:Connect(descendant.Activated, function()
			self.Loadout:SelectWeapon(weapon_id)
		end)
	end

	self.Trove:Connect(self.Loadout.InventoryChanged, function(entries, selected_slot)
		self:_show_inventory(entries, selected_slot)
	end)
	self.Trove:Connect(self.Loadout.EquippedChanged, function(weapon_id)
		self:_show_equipped(weapon_id)
	end)

	-- Show whatever the session already knows; later changes arrive as signals.
	self:_show_inventory(self.Loadout.Entries, self.Loadout.SelectedSlot)
	self:_show_equipped(self.Loadout.EquippedId)
end

-- The default weapon is implicit and always available; any other button is
-- shown only while the server reports an item granting that weapon in a slot.
function WeaponMenu:_show_inventory(entries, selected_slot)
	if typeof(entries) ~= "table" then
		return
	end

	local owned = { [Catalog.DefaultId] = true }
	local selected_weapon = Catalog.DefaultId

	for _, entry in ipairs(entries) do
		if typeof(entry) ~= "table"
			or typeof(entry.Slot) ~= "number"
			or typeof(entry.ItemId) ~= "string" then
			continue
		end

		local item = ItemCatalog.Get(entry.ItemId)
		if not item then
			continue
		end

		owned[item.WeaponId] = true
		if entry.Slot == selected_slot then
			selected_weapon = item.WeaponId
		end
	end

	for weapon_id, button in pairs(self.Buttons) do
		button.Visible = owned[weapon_id] == true
	end

	self:_set_selected(selected_weapon)
end

function WeaponMenu:_show_equipped(weapon_id)
	self:_set_selected(weapon_id)
end

function WeaponMenu:_set_selected(weapon_id)
	if not self.Buttons[weapon_id] then
		return
	end

	self.SelectedWeapon = weapon_id

	for id, button in pairs(self.Buttons) do
		local selection = button:FindFirstChild("Selection", true)
		if selection and selection:IsA("GuiObject") then
			selection.Visible = id == weapon_id
		end
	end
end

function WeaponMenu:Destroy()
	self.Trove:Destroy()
	table.clear(self.Buttons)
	self.Gui = nil
end

return WeaponMenu
