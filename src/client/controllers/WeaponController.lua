-- Tracks the locally equipped weapon definition and resolves its wielded parts
-- inside the server-attached weapon model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local WeaponController = {}
WeaponController.__index = WeaponController

function WeaponController.new(deps)
	Deps.check(deps, "WeaponController", { "character" })

	return setmetatable({
		Character = deps.character,
		Equipped = nil,
		-- Wield lookups for the equipped weapon's model. Valid only while
		-- CachedModel is still parented to the character.
		CachedModel = nil,
		WieldCache = {},
	}, WeaponController)
end

function WeaponController:_invalidate()
	self.CachedModel = nil
	table.clear(self.WieldCache)
end

-- Returns the equipped weapon's model under the character, rebuilding the
-- wield cache when the model was replaced or left the character.
function WeaponController:_model()
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

function WeaponController:GetWielded(wield_name)
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

function WeaponController:EquipById(weapon_id)
	local weapon = Catalog.Get(weapon_id)
	if not weapon then
		return false
	end

	return self:Equip(weapon)
end

function WeaponController:Equip(weapon)
	if not Catalog.IsEquippable(weapon) then
		return false
	end

	self.Equipped = weapon
	self:_invalidate()
	return true
end

function WeaponController:Destroy()
	self.Equipped = nil
	self:_invalidate()
end

return WeaponController
