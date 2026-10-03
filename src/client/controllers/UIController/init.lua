local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

-- Missing templates are a content problem, not a runtime one; report each once
-- per session instead of on every UIController construction.
local WarnedTemplates = {}

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
	-- Each UI module is optional: one failing module must not take down the
	-- others or the gameplay controllers that start after UI.
	for _, child in script:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(function()
			return require(child).new(self)
		end)
		if not ok then
			warn(("UIController: %s failed to start: %s"):format(child.Name, tostring(result)))
			continue
		end

		self.Modules[child.Name] = result
		self.Trove:Add(result)
	end
end

-- Clones ReplicatedStorage.ui[name] into PlayerGui, or returns nil (warning
-- once) when the template is absent so the caller can run as a no-op.
function UIController:CloneTemplate(name)
	local templates = ReplicatedStorage:FindFirstChild("ui")
	local template = templates and templates:FindFirstChild(name)
	if not template or not template:IsA("ScreenGui") then
		if not WarnedTemplates[name] then
			WarnedTemplates[name] = true
			warn(("UIController: ScreenGui template ReplicatedStorage.ui.%s is missing; %s UI is disabled"):format(name, name))
		end
		return nil
	end

	local gui = template:Clone()
	-- PlayerGui destroys ResetOnSpawn guis on respawn, which would leave the
	-- module holding dead instances for the rest of the session.
	gui.ResetOnSpawn = false
	gui.Parent = self.PlayerGui
	return gui
end

function UIController:Get(name)
	return self.Modules[name]
end

function UIController:_dispatch(method, ...)
	for name, module in pairs(self.Modules) do
		if not module[method] then
			continue
		end

		local ok, err = pcall(module[method], module, ...)
		if not ok then
			warn(("UIController: %s:%s failed: %s"):format(name, method, tostring(err)))
		end
	end
end

function UIController:BindCharacter(character_controller)
	if self._destroyed then
		return
	end
	self.Character = character_controller
	self:_dispatch("BindCharacter", character_controller)
end

-- entries is the dense, slot-sorted { Slot, WeaponId } array from Inventory.Changed.
function UIController:SetInventory(entries, selected_slot)
	if self._destroyed then
		return
	end
	self:_dispatch("SetInventory", entries, selected_slot)
end

function UIController:SetEquipped(weapon_id)
	if self._destroyed then
		return
	end
	self:_dispatch("SetEquipped", weapon_id)
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
