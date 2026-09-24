local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local WeaponRemote = ReplicatedStorage.remotes.Weapon

local WeaponMenuController = {}
WeaponMenuController.__index = WeaponMenuController

function WeaponMenuController.new()
	local self = setmetatable({
		Trove = Trove.new(),
		Buttons = {},
		SelectedWeapon = nil,

		SelectionChanged = Signal.new(),
	}, WeaponMenuController)

	self.Trove:Add(self.SelectionChanged)
	self:_start()

	return self
end

function WeaponMenuController:_start()
	local player = Players.LocalPlayer
	local player_gui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "WeaponMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player_gui
	self.Trove:Add(gui)

	local frame = Instance.new("Frame")
	frame.Name = "Weapons"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -88)
	frame.Size = UDim2.fromOffset(0, 38)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundTransparency = 0.15
	frame.Parent = gui
	self.Trove:Add(frame)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 4)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = frame

	local weapon_ids = {}

	for _, module in WeaponsFolder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		local weapon = require(module)
		if weapon.Type ~= "Melee" then
			continue
		end

		weapon_ids[#weapon_ids + 1] = module.Name
	end

	table.sort(weapon_ids)

	for _, weapon_id in weapon_ids do
		local button = Instance.new("TextButton")
		button.Name = weapon_id
		button.Size = UDim2.fromOffset(88, 30)
		button.BackgroundTransparency = 0.35
		button.AutoButtonColor = true
		button.Text = weapon_id
		button.TextSize = 14
		button.Font = Enum.Font.GothamMedium
		button.Parent = frame

		local button_corner = Instance.new("UICorner")
		button_corner.CornerRadius = UDim.new(0, 4)
		button_corner.Parent = button

		self.Trove:Connect(
			button.Activated,
			function()
				WeaponRemote:FireServer("Equip", weapon_id)
			end
		)

		self.Buttons[weapon_id] = button
	end

	self.SelectedWeapon = weapon_ids[1]

	self.Trove:Connect(
		WeaponRemote.OnClientEvent,
		function(action, weapon_id)
			if action == "Equipped" then
				self:_set_selected(weapon_id)
			end
		end
	)

	self:_refresh_buttons()
end

function WeaponMenuController:_set_selected(weapon_id)
	if self.SelectedWeapon == weapon_id then
		self:_refresh_buttons()
		return
	end

	if not self.Buttons[weapon_id] then
		return
	end

	self.SelectedWeapon = weapon_id
	self:_refresh_buttons()
	self.SelectionChanged:Fire(weapon_id)
end

function WeaponMenuController:_refresh_buttons()
	for weapon_id, button in pairs(self.Buttons) do
		button.BackgroundTransparency = weapon_id == self.SelectedWeapon and 0 or 0.35
	end
end

function WeaponMenuController:Destroy()
	self.Trove:Destroy()
end

return WeaponMenuController
