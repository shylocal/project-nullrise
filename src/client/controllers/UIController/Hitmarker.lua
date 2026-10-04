local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)

-- Flashes the hitmarker on every server-confirmed hit. It subscribes to the
-- session CombatClient once, so it keeps working across respawns.
local Hitmarker = {}
Hitmarker.__index = Hitmarker

local DISPLAY_TIME = 0.12

function Hitmarker.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		Gui = nil,
		Visual = nil,
		HitId = 0,
	}, Hitmarker)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function Hitmarker:_start()
	-- A missing template leaves Visual nil, which makes every method a no-op.
	local gui = self.UIController:CloneTemplate("Hitmarker")
	if not gui then
		return
	end

	self.Gui = gui
	self.Trove:Add(gui)
	self.Trove:Connect(gui.Destroying, function()
		if self.Gui == gui then
			self.Gui = nil
			self.Visual = nil
		end
	end)

	self.Visual = gui:FindFirstChild("Hitmarker", true)

	if not self.Visual then
		return
	end

	self.Visual.Visible = false
	self.Trove:Connect(self.UIController.Combat.HitConfirmed, function()
		self:Show()
	end)
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
	self.Trove:Destroy()
	self.Visual = nil
	self.Gui = nil
end

return Hitmarker
