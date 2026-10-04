--!strict
-- Content contracts, composed first: the weapon templates in
-- ServerStorage.weapon_models are verified against the Catalog before any
-- gameplay service is built. In Studio a mismatch stops the boot (the Runtime
-- reports it as "failed to start AssetContracts"); live servers warn and run.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)

local server = script.Parent.Parent
local AssetContracts = require(server.AssetContracts)
local Core = require(server.compose.Core)

return function(rt: Runtime.Runtime, env: Core.ServerEnv): ()
	rt:Add("AssetContracts", function()
		AssetContracts.Report(AssetContracts.Verify(Catalog, env.WeaponModels), env.IsStudio)
		return { Destroy = function() end }
	end)
end
