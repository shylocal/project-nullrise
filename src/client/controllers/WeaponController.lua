--!strict
-- Tracks the locally equipped weapon definition and resolves its wielded parts
-- inside the server-attached weapon model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

export type Deps = {
	character: Model,
}

type WeaponControllerFields = {
	Character: Model,
	Equipped: Catalog.WeaponDefinition?,
	-- Wield lookups for the equipped weapon's model. Valid only while
	-- CachedModel is still parented to the character.
	CachedModel: Instance?,
	WieldCache: { [string]: Instance? },
}

local WeaponController = {}
WeaponController.__index = WeaponController

export type WeaponController = typeof(setmetatable({} :: WeaponControllerFields, WeaponController))

function WeaponController.new(deps: Deps): WeaponController
	Deps.check(deps, "WeaponController", { "character" })

	return setmetatable({
		Character = deps.character,
		Equipped = nil,
		CachedModel = nil,
		WieldCache = {},
	} :: WeaponControllerFields, WeaponController)
end

function WeaponController._invalidate(self: WeaponController)
	self.CachedModel = nil
	table.clear(self.WieldCache)
end

-- Returns the equipped weapon's model under the character, rebuilding the
-- wield cache when the model was replaced or left the character.
function WeaponController._model(self: WeaponController): Instance?
	local weapon = self.Equipped
	if not weapon then
		return nil
	end

	local cached = self.CachedModel
	if cached and cached.Parent == self.Character and cached.Name == weapon.Model then
		return cached
	end

	self:_invalidate()
	local model = self.Character:FindFirstChild(weapon.Model)
	self.CachedModel = model
	return model
end

function WeaponController.GetWielded(self: WeaponController, wield_name: string): Instance?
	local model = self:_model()
	if not model then
		return nil
	end

	local cached = self.WieldCache[wield_name]
	if cached and cached:IsDescendantOf(model) then
		return cached
	end

	-- Misses are not cached: parts can still be replicating in.
	local wielded = model:FindFirstChild(wield_name, true)
	self.WieldCache[wield_name] = wielded
	return wielded
end

function WeaponController.EquipById(self: WeaponController, weapon_id: string): boolean
	local weapon = Catalog.Get(weapon_id)
	if not weapon then
		return false
	end

	return self:Equip(weapon)
end

function WeaponController.Equip(self: WeaponController, weapon: Catalog.WeaponDefinition): boolean
	if not Catalog.IsEquippable(weapon) then
		return false
	end

	self.Equipped = weapon
	self:_invalidate()
	return true
end

function WeaponController.Destroy(self: WeaponController)
	self.Equipped = nil
	self:_invalidate()
end

return WeaponController
