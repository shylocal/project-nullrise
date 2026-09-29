-- Central weapon-definition lookup shared by client and server.
-- Add weapon definitions as ModuleScripts beside this file.
local Catalog = {}

local WeaponsFolder = script.Parent
local Definitions = {}
local FailedModules = {}

function Catalog.Get(weapon_id)
	if typeof(weapon_id) ~= "string" or weapon_id == "" then
		return nil
	end

	local module = WeaponsFolder:FindFirstChild(weapon_id)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end

	local cached = Definitions[module]
	if cached then
		return cached
	end

	if FailedModules[module] then
		return nil
	end

	local ok, definition = pcall(require, module)
	if not ok then
		FailedModules[module] = true
		warn(("Failed to load weapon definition %s: %s"):format(module:GetFullName(), tostring(definition)))
		return nil
	end

	if typeof(definition) ~= "table" then
		return nil
	end

	Definitions[module] = definition
	return definition
end

function Catalog.IsMelee(weapon)
	return typeof(weapon) == "table" and weapon.Type == "Melee"
end

return Catalog
