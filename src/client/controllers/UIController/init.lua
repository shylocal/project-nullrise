local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

-- Missing templates are a content problem, not a runtime one; report each once
-- per session instead of on every UIController construction.
local WarnedTemplates = {}

-- Session-lifetime UI host. Each child ModuleScript is an optional UI module
-- built as Module.new(ui); modules subscribe to the session clients
-- (ui.Combat, ui.Loadout) themselves, so they survive respawns.
local UIController = {}
UIController.__index = UIController

function UIController.new(deps)
	Deps.check(deps, "UIController", { "combat", "loadout", "player_gui" })

	local self = setmetatable({
		Trove = Trove.new(),
		Modules = {},
		Combat = deps.combat,
		Loadout = deps.loadout,
		PlayerGui = deps.player_gui,
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

-- Clones the named ScreenGui template into PlayerGui, or returns nil (warning
-- once) when the template is absent so the caller can run as a no-op.
function UIController:CloneTemplate(name)
	local folder_name = Config.World.Folders.UiTemplates
	local templates = ReplicatedStorage:FindFirstChild(folder_name)
	local template = templates and templates:FindFirstChild(name)
	if not template or not template:IsA("ScreenGui") then
		if not WarnedTemplates[name] then
			WarnedTemplates[name] = true
			warn(("UIController: ScreenGui template ReplicatedStorage.%s.%s is missing; %s UI is disabled"):format(folder_name, name, name))
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

function UIController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
	table.clear(self.Modules)
end

return UIController
