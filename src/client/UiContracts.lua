--!strict
-- Verifies the Studio-authored UI templates (ReplicatedStorage.ui) against the
-- weapon Catalog at client boot: every GuiButton in the WeaponMenu template
-- that carries a WeaponId attribute must name a Catalog weapon. Templates are
-- optional content, so a missing WeaponMenu is not an error.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local World = require(ReplicatedStorage.shared.config).World

local WEAPON_ID_ATTRIBUTE = World.Attributes.WeaponId
local WEAPON_MENU = "WeaponMenu"

export type CatalogLike = {
	Ids: () -> { string },
	Get: (id: any) -> any,
}

local UiContracts = {}

-- `ui_folder` is ReplicatedStorage.ui (nil when the place lacks it).
function UiContracts.Verify(catalog: CatalogLike, ui_folder: Instance?): { string }
	local errors = {}
	local menu = ui_folder and ui_folder:FindFirstChild(WEAPON_MENU)
	if menu == nil then
		return errors
	end
	for _, descendant in ipairs(menu:GetDescendants()) do
		if not descendant:IsA("GuiButton") then
			continue
		end
		local weapon_id = descendant:GetAttribute(WEAPON_ID_ATTRIBUTE)
		if weapon_id ~= nil and catalog.Get(weapon_id) == nil then
			table.insert(
				errors,
				("%s.%s: %s '%s' is not a Catalog weapon id"):format(
					WEAPON_MENU,
					descendant:GetFullName():sub(#menu:GetFullName() + 2),
					WEAPON_ID_ATTRIBUTE,
					tostring(weapon_id)
				)
			)
		end
	end
	table.sort(errors)
	return errors
end

-- Studio stops the client boot with every problem listed; live clients warn.
function UiContracts.Report(errors: { string }, is_studio: boolean): ()
	if #errors == 0 then
		return
	end
	if is_studio then
		error("[UiContracts] UI templates do not match the Catalog:\n" .. table.concat(errors, "\n"), 0)
	end
	for _, message in ipairs(errors) do
		warn("[UiContracts] " .. message)
	end
end

return table.freeze(UiContracts)
