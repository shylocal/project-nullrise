-- Central weapon-definition lookup shared by client and server.
-- Weapon definitions are ModuleScripts beside this file. Only IDs listed in
-- WEAPON_IDS are weapons; other modules here (Validator, CombatConfig, this
-- Catalog) are never returned by Get.
local Catalog = {}

local Validator = require(script.Parent.Validator)
local WeaponsFolder = script.Parent

local WEAPON_IDS = {
	"Fists",
	"Katana",
}

local Definitions = {}

-- Load and validate every weapon once when the catalog is first required. An
-- invalid or missing definition is a content bug, so fail loudly instead of
-- letting combat run with partially-defined data.
for _, weapon_id in ipairs(WEAPON_IDS) do
	local module = WeaponsFolder:FindFirstChild(weapon_id)
	if not module or not module:IsA("ModuleScript") then
		error(("Weapon definition %s is missing from %s"):format(weapon_id, WeaponsFolder:GetFullName()), 0)
	end

	local definition = require(module)
	local ok, reason = Validator.validate(definition)
	if not ok then
		error(("Invalid weapon definition %s: %s"):format(weapon_id, tostring(reason)), 0)
	end

	Definitions[weapon_id] = definition
end

function Catalog.Get(weapon_id)
	if typeof(weapon_id) ~= "string" then
		return nil
	end

	return Definitions[weapon_id]
end

function Catalog.IsMelee(weapon)
	return typeof(weapon) == "table" and weapon.Type == "Melee"
end

return Catalog
