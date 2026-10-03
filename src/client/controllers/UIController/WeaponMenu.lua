local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local InventoryRemote = ReplicatedStorage.remotes.Inventory
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local FISTS_ID = "Fists"

-- Display-only mirror of server inventory state. PlayerController forwards
-- Inventory.Changed and Weapon.Equipped through UIController; button presses
-- only request a selection and never change the display directly.
local WeaponMenu = {}
WeaponMenu.__index = WeaponMenu

function WeaponMenu.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
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

		local weapon = Catalog.Get(weapon_id)
		if not Catalog.IsMelee(weapon) then
			continue
		end

		self.Buttons[weapon_id] = descendant

		self.Trove:Connect(
			descendant.Activated,
			function()
				InventoryRemote:FireServer(Protocol.Inventory.SelectItem, weapon_id)
			end
		)
	end

	self:_set_selected(FISTS_ID)
end

-- Fists are implicit and always available; any other button is shown only
-- while the server reports that weapon in a slot.
function WeaponMenu:SetInventory(entries, selected_slot)
	if typeof(entries) ~= "table" then
		return
	end

	local owned = { [FISTS_ID] = true }
	local selected_weapon = FISTS_ID

	for _, entry in ipairs(entries) do
		if typeof(entry) ~= "table"
			or typeof(entry.Slot) ~= "number"
			or typeof(entry.WeaponId) ~= "string" then
			continue
		end

		owned[entry.WeaponId] = true
		if entry.Slot == selected_slot then
			selected_weapon = entry.WeaponId
		end
	end

	for weapon_id, button in pairs(self.Buttons) do
		button.Visible = owned[weapon_id] == true
	end

	self:_set_selected(selected_weapon)
end

function WeaponMenu:SetEquipped(weapon_id)
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
