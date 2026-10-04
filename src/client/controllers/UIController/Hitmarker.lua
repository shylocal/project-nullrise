--!strict
local Trove = require(script.Parent.Parent.Parent.ClientTrove)
-- Type only: UI modules are built by UIController after it has loaded.
local UIController = require(script.Parent)

type Trove = Trove.Trove

type HitmarkerFields = {
	Trove: Trove,
	UIController: UIController.UIController,
	Gui: ScreenGui?,
	Visual: GuiObject?,
	HitId: number,
}

-- Flashes the hitmarker on every server-confirmed hit. It subscribes to the
-- session CombatClient once, so it keeps working across respawns.
local Hitmarker = {}
Hitmarker.__index = Hitmarker

export type Hitmarker = typeof(setmetatable({} :: HitmarkerFields, Hitmarker))

local DISPLAY_TIME = 0.12

function Hitmarker.new(ui_controller: UIController.UIController): Hitmarker
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		Gui = nil,
		Visual = nil,
		HitId = 0,
	} :: HitmarkerFields, Hitmarker)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function Hitmarker._start(self: Hitmarker)
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

	local visual = gui:FindFirstChild("Hitmarker", true)
	if not visual then
		return
	end
	assert(visual:IsA("GuiObject"), "Hitmarker: the Hitmarker visual must be a GuiObject")

	self.Visual = visual
	visual.Visible = false
	self.Trove:Connect(self.UIController.Combat.HitConfirmed, function()
		self:Show()
	end)
end

function Hitmarker.Show(self: Hitmarker)
	local visual = self.Visual
	if not visual then
		return
	end

	self.HitId += 1
	local hit_id = self.HitId

	visual.Visible = true

	task.delay(DISPLAY_TIME, function()
		local current = self.Visual
		if self.HitId == hit_id and current then
			current.Visible = false
		end
	end)
end

function Hitmarker.Destroy(self: Hitmarker)
	self.Trove:Destroy()
	self.Visual = nil
	self.Gui = nil
end

return Hitmarker
