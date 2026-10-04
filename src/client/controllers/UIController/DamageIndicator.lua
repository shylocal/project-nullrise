--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(script.Parent.Parent.Parent.ClientTrove)
local Config = require(ReplicatedStorage.shared.config)
-- Type only: UI modules are built by UIController after it has loaded.
local UIController = require(script.Parent)

type Trove = Trove.Trove

type DamageIndicatorFields = {
	Trove: Trove,
	UIController: UIController.UIController,
	Gui: ScreenGui?,
	Flash: GuiObject?,
	FlashId: number,
}

-- Flashes a screen overlay when the local character takes damage
-- (CombatClient.Damaged). The ScreenGui template "DamageIndicator", with a
-- GuiObject named "Flash", is optional: without it this module does nothing.
local DamageIndicator = {}
DamageIndicator.__index = DamageIndicator

export type DamageIndicator = typeof(setmetatable({} :: DamageIndicatorFields, DamageIndicator))

local TEMPLATE_NAME = "DamageIndicator"
local FLASH_NAME = "Flash"
local DISPLAY_TIME = 0.15

function DamageIndicator.new(ui_controller: UIController.UIController): DamageIndicator
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		Gui = nil,
		Flash = nil,
		FlashId = 0,
	} :: DamageIndicatorFields, DamageIndicator)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

local function has_template(): boolean
	local templates = ReplicatedStorage:FindFirstChild(Config.World.Folders.UiTemplates)
	local template = templates and templates:FindFirstChild(TEMPLATE_NAME)
	return template ~= nil and template:IsA("ScreenGui")
end

function DamageIndicator._start(self: DamageIndicator)
	-- The template is optional, so its absence is not reported.
	if not has_template() then
		return
	end

	local gui = self.UIController:CloneTemplate(TEMPLATE_NAME)
	if not gui then
		return
	end

	self.Gui = gui
	self.Trove:Add(gui)
	self.Trove:Connect(gui.Destroying, function()
		if self.Gui == gui then
			self.Gui = nil
			self.Flash = nil
		end
	end)

	local flash = gui:FindFirstChild(FLASH_NAME, true)
	if not flash or not flash:IsA("GuiObject") then
		return
	end

	self.Flash = flash
	flash.Visible = false
	self.Trove:Connect(self.UIController.Combat.Damaged, function()
		self:Show()
	end)
end

function DamageIndicator.Show(self: DamageIndicator)
	local flash = self.Flash
	if not flash then
		return
	end

	self.FlashId += 1
	local flash_id = self.FlashId
	flash.Visible = true

	task.delay(DISPLAY_TIME, function()
		local current = self.Flash
		if self.FlashId == flash_id and current then
			current.Visible = false
		end
	end)
end

function DamageIndicator.Destroy(self: DamageIndicator)
	self.Trove:Destroy()
	self.Flash = nil
	self.Gui = nil
end

return DamageIndicator
