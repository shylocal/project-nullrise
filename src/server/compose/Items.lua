--!strict
-- Item services: the persisted profile, the inventory it backs, and the
-- weapon the inventory selection equips. PlayerDataService is the first
-- player component, so later components read loaded data on join.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.shared.config)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Schema = require(ReplicatedStorage.shared.data.Schema)

local server = script.Parent.Parent
local Core = require(server.compose.Core)
local Remotes = require(server.compose.Remotes)
local PlayerDataService = require(server.services.PlayerDataService)
local InventoryService = require(server.services.InventoryService)
local WeaponService = require(server.services.WeaponService)

-- ProfileStore binds BindToClose itself and, in Studio without API access,
-- falls back to its own mock automatically. It is required lazily so that
-- requiring this module (for example from a spec) does not start
-- ProfileStore's DataStore probe.
local function create_store(env: Core.ServerEnv): PlayerDataService.StoreLike
	local ProfileStore = (require :: any)(server.vendor.ProfileStore)
	local store = ProfileStore.New(Config.Data.StoreName, Schema.Template())

	if env.IsStudio and Config.Data.UseMockInStudio then
		warn("[PlayerData] Studio is using the ProfileStore mock; data is not saved")
		-- The Mock table has no metatable, so it would not see the module's
		-- IsClosing flag that the real store inherits through __index.
		-- PlayerDataService reads it to tell a shutdown from a session steal.
		return setmetatable(store.Mock, {
			__index = function(_, key)
				if key == "IsClosing" then
					return ProfileStore.IsClosing
				end
				return nil
			end,
		}) :: any
	end

	return store
end

return function(rt: Runtime.Runtime, env: Core.ServerEnv): ()
	rt:Add("PlayerDataService", function(get)
		return PlayerDataService.new({
			players = get("PlayerService"),
			store = create_store(env),
			is_studio = env.IsStudio,
			config = Config.Data,
			telemetry = get("Telemetry"),
		})
	end)

	rt:Add("InventoryService", function(get)
		return InventoryService.new({
			players = get("PlayerService"),
			data = get("PlayerDataService"),
			remote = Remotes.event(env.Remotes, "Inventory"),
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)

	rt:Add("WeaponService", function(get)
		return WeaponService.new({
			players = get("PlayerService"),
			inventory = get("InventoryService"),
			remote = Remotes.event(env.Remotes, "Weapon"),
			weapon_models = env.WeaponModels,
			scheduler = env.Scheduler,
		})
	end)
end
