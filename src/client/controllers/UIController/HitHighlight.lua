local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)

-- Briefly highlights every character the server reports as hit nearby
-- (CombatClient.FxHit). Highlights are pooled and need no template.
local HitHighlight = {}
HitHighlight.__index = HitHighlight

local DISPLAY_TIME = 0.12
-- Roblox renders a limited number of Highlights at once; stay well below it.
local MAX_ACTIVE = 8
local FILL_COLOR = Color3.new(1, 1, 1)
local FILL_TRANSPARENCY = 0.6
local OUTLINE_TRANSPARENCY = 0.2

function HitHighlight.new(ui_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		UIController = ui_controller,
		-- Unparented highlights ready for reuse.
		Free = {},
		-- victim -> { Highlight, Token }
		Active = {},
		ActiveCount = 0,
		_destroyed = false,
	}, HitHighlight)

	self.Trove:Connect(ui_controller.Combat.FxHit, function(victim)
		self:Show(victim)
	end)

	return self
end

function HitHighlight:_take()
	local highlight = table.remove(self.Free)
	if highlight then
		return highlight
	end

	highlight = Instance.new("Highlight")
	highlight.FillColor = FILL_COLOR
	highlight.FillTransparency = FILL_TRANSPARENCY
	highlight.OutlineColor = FILL_COLOR
	highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	return highlight
end

function HitHighlight:_release(victim, entry)
	if self.Active[victim] ~= entry then
		return
	end
	self.Active[victim] = nil
	self.ActiveCount -= 1

	local highlight = entry.Highlight
	highlight.Adornee = nil
	-- A highlight destroyed along with its victim cannot be reused.
	if self._destroyed or #self.Free >= MAX_ACTIVE or not highlight:IsDescendantOf(game) then
		highlight:Destroy()
		return
	end
	highlight.Parent = nil
	table.insert(self.Free, highlight)
end

function HitHighlight:Show(victim)
	if self._destroyed or typeof(victim) ~= "Instance" or victim.Parent == nil then
		return
	end

	local entry = self.Active[victim]
	if not entry then
		if self.ActiveCount >= MAX_ACTIVE then
			return
		end
		local highlight = self:_take()
		highlight.Adornee = victim
		-- Parented to the victim so it disappears with the character.
		highlight.Parent = victim
		entry = { Highlight = highlight, Token = 0 }
		self.Active[victim] = entry
		self.ActiveCount += 1
	end

	entry.Token += 1
	local token = entry.Token
	task.delay(DISPLAY_TIME, function()
		if entry.Token == token then
			self:_release(victim, entry)
		end
	end)
end

function HitHighlight:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()

	local active = table.clone(self.Active)
	for victim, entry in pairs(active) do
		self:_release(victim, entry)
	end
	for _, highlight in ipairs(self.Free) do
		highlight:Destroy()
	end
	table.clear(self.Free)
end

return HitHighlight
