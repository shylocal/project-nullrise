local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local UITemplates = ReplicatedStorage.ui

local Hitmarker = {}
Hitmarker.__index = Hitmarker

local DISPLAY_TIME = 0.12

function Hitmarker.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		CharacterTrove = nil,
		UIController = ui_controller,
		Gui = nil,
		Visual = nil,
		HitId = 0,
	}, Hitmarker)

	self:_start()

	return self
end

function Hitmarker:_start()
	local gui = UITemplates.Hitmarker:Clone()
	gui.Parent = self.UIController.PlayerGui

	self.Gui = gui
	self.Visual = gui:FindFirstChild("Hitmarker", true)

	if self.Visual then
		self.Visual.Visible = false
	end
end

function Hitmarker:BindCharacter(character_controller)
	if self.CharacterTrove then
		self.CharacterTrove:Destroy()
		self.CharacterTrove = nil
	end

	if not character_controller then
		return
	end

	if not self.Visual then
		return
	end

	local combat_controller = character_controller.CombatController
	if not combat_controller then
		return
	end

	self.CharacterTrove = Trove.new()

	self.CharacterTrove:Connect(
		combat_controller.Hit,
		function()
			self:Show()
		end
	)
end

function Hitmarker:Show()
	if not self.Visual then
		return
	end

	self.HitId += 1
	local hit_id = self.HitId

	self.Visual.Visible = true

	task.delay(DISPLAY_TIME, function()
		if self.HitId == hit_id and self.Visual then
			self.Visual.Visible = false
		end
	end)
end

function Hitmarker:Destroy()
	if self.CharacterTrove then
		self.CharacterTrove:Destroy()
		self.CharacterTrove = nil
	end

	self.Trove:Destroy()
	self.Visual = nil
	self.Gui = nil
end

return Hitmarker
