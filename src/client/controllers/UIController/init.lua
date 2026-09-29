local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local UIController = {}
UIController.__index = UIController

function UIController.new()
	local self = setmetatable({
		Trove = Trove.new(),
		Modules = {},
		PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui"),
		Character = nil,
		_destroyed = false,
	}, UIController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function UIController:_start()
	for _, child in script:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local module = require(child)
		local controller = module.new(self)

		self.Modules[child.Name] = controller
		self.Trove:Add(controller)
	end
end

function UIController:Get(name)
	return self.Modules[name]
end

function UIController:BindCharacter(character_controller)
	self.Character = character_controller

	for _, module in pairs(self.Modules) do
		if module.BindCharacter then
			module:BindCharacter(character_controller)
		end
	end
end

function UIController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
	self.Character = nil
	table.clear(self.Modules)
end

return UIController
