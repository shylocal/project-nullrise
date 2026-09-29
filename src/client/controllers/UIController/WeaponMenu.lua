local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local UITemplates = ReplicatedStorage.ui
local WeaponRemote = ReplicatedStorage.remotes.Weapon
local InventoryRemote = ReplicatedStorage.remotes.Inventory
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local WeaponMenu = {}
WeaponMenu.__index = WeaponMenu

function WeaponMenu.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		Gui = nil,
		Buttons = {},
		SelectedWeapon = nil,

		SelectionChanged = Signal.new(),
	}, WeaponMenu)

	self.Trove:Add(self.SelectionChanged)
	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function WeaponMenu:_start()
	local gui = UITemplates.WeaponMenu:Clone()
	gui.Parent = self.UIController.PlayerGui
	self.Gui = gui
	self.Trove:Add(gui)

	for _, descendant in gui:GetDescendants() do
		if not descendant:IsA("GuiButton") then
			continue
		end

		local weapon_id = descendant:GetAttribute("WeaponId")
		if typeof(weapon_id) ~= "string" then
			continue
		end

		local weapon = Catalog.Get(weapon_id)
		if not weapon then
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

	if self.Buttons.Fists then
		self:_set_selected("Fists", false)
	end

	self.Trove:Connect(
		WeaponRemote.OnClientEvent,
		function(action, weapon_id)
			if action == Protocol.Weapon.Equipped then
				self:_set_selected(weapon_id, true)
			end
		end
	)
end

function WeaponMenu:_set_selected(weapon_id, fire_signal)
	local button = self.Buttons[weapon_id]
	if not button then
		return
	end

	self.SelectedWeapon = weapon_id

	for id, selected_button in pairs(self.Buttons) do
		local selection = selected_button:FindFirstChild("Selection", true)
		if selection and selection:IsA("GuiObject") then
			selection.Visible = id == weapon_id
		end
	end

	if fire_signal then
		self.SelectionChanged:Fire(weapon_id)
	end
end

function WeaponMenu:Destroy()
	self.Trove:Destroy()
	table.clear(self.Buttons)
end

return WeaponMenu
