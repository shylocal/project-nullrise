local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local PCInput = require(script.Parent.Parent.input.PC)
local MobileInput = require(script.Parent.Parent.input.Mobile)

local InputController = {}
InputController.__index = InputController

function InputController.new()
	local self = setmetatable({
		Trove = Trove.new(),
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
	}, InputController)

	self.Trove:Add(self.ActionBegan)
	self.Trove:Add(self.ActionEnded)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function InputController:_start()
	self.Trove:Connect(UserInputService.WindowFocusReleased, function()
		self:_release_all()
	end)

	local began = function(action)
		self:_began(action)
	end

	local ended = function(action)
		self:_ended(action)
	end

	self.Trove:Add(PCInput.new(began, ended))

	if UserInputService.TouchEnabled then
		self.Trove:Add(MobileInput.new(began, ended))
	end
end

function InputController:_began(action)
	if self.Down[action] then
		return
	end

	self.Down[action] = true
	self.ActionBegan:Fire(action)
end

function InputController:_ended(action)
	if not self.Down[action] then
		return
	end

	self.Down[action] = nil
	self.ActionEnded:Fire(action)
end

-- Release every held action when Roblox loses window focus. InputEnded is not
-- guaranteed to arrive after an application switch or an overlay transition.
function InputController:_release_all()
	local held_actions = {}
	for action in pairs(self.Down) do
		table.insert(held_actions, action)
	end

	for _, action in ipairs(held_actions) do
		self:_ended(action)
	end
end

function InputController:IsDown(action)
	return self.Down[action] == true
end

function InputController:Destroy()
	table.clear(self.Down)
	self.Trove:Destroy()
end

return InputController
