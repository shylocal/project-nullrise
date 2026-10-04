--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(script.Parent.Parent.ClientTrove)
local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local CombatClient = require(script.Parent.Parent.session.CombatClient)
local LoadoutClient = require(script.Parent.Parent.session.LoadoutClient)

type Trove = Trove.Trove

export type Deps = {
	combat: CombatClient.CombatClient,
	loadout: LoadoutClient.LoadoutClient,
	player_gui: Instance,
}

-- A UI module instance (Module.new(ui) result), destroyed with the controller.
export type UIModule = { Destroy: (self: any) -> () }

type UIControllerFields = {
	Trove: Trove,
	Modules: { [string]: UIModule },
	Combat: CombatClient.CombatClient,
	Loadout: LoadoutClient.LoadoutClient,
	PlayerGui: Instance,
	_destroyed: boolean,
}

-- Missing templates are a content problem, not a runtime one; report each once
-- per session instead of on every UIController construction.
local warned_templates: { [string]: boolean } = {}

-- Session-lifetime UI host. Each child ModuleScript is an optional UI module
-- built as Module.new(ui); modules subscribe to the session clients
-- (ui.Combat, ui.Loadout) themselves, so they survive respawns.
local UIController = {}
UIController.__index = UIController

export type UIController = typeof(setmetatable({} :: UIControllerFields, UIController))

function UIController.new(deps: Deps): UIController
	Deps.check(deps, "UIController", { "combat", "loadout", "player_gui" })

	local self = setmetatable({
		Trove = Trove.new(),
		Modules = {},
		Combat = deps.combat,
		Loadout = deps.loadout,
		PlayerGui = deps.player_gui,
		_destroyed = false,
	} :: UIControllerFields, UIController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function UIController._start(self: UIController)
	-- Each UI module is optional: one failing module must not take down the
	-- others or the gameplay controllers that start after UI.
	for _, child in script:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(function(): UIModule
			-- UI modules are discovered at runtime, so the analyzer cannot
			-- resolve them; each exports new(ui) -> UIModule.
			local module: any = (require :: any)(child)
			return module.new(self)
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
function UIController.CloneTemplate(self: UIController, name: string): ScreenGui?
	local folder_name = Config.World.Folders.UiTemplates
	local templates = ReplicatedStorage:FindFirstChild(folder_name)
	local template = templates and templates:FindFirstChild(name)
	if not template or not template:IsA("ScreenGui") then
		if not warned_templates[name] then
			warned_templates[name] = true
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

-- The named UI module's instance, or nil when it is absent or failed to start.
function UIController.Get(self: UIController, name: string): UIModule?
	return self.Modules[name]
end

function UIController.Destroy(self: UIController)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
	table.clear(self.Modules)
end

return UIController
