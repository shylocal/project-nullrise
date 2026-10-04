--!strict
-- Equip animation layer.
local Types = require(script.Parent.Types)

type Track = Types.Track

type WeaponFields = {
	Controller: Types.Host,
	Weapon: Types.WeaponDefinition?,
	EquipTrack: Track?,
}

local Weapon = {}
Weapon.__index = Weapon

export type Weapon = typeof(setmetatable({} :: WeaponFields, Weapon))

function Weapon.new(animation_controller: Types.Host): Weapon
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		EquipTrack = nil,
	} :: WeaponFields, Weapon)

	return self
end

function Weapon.SetWeapon(self: Weapon, weapon: Types.WeaponDefinition?)
	self.Weapon = weapon
	self:_load()
	self:PlayEquip()
end

function Weapon._load(self: Weapon): Track?
	self.EquipTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return nil
	end

	local track = self.Controller:Track("Equip", weapon.Animations and weapon.Animations.Equip)
	self.EquipTrack = track

	return track
end

function Weapon.PlayEquip(self: Weapon): Track?
	local track = self.EquipTrack or self:_load()
	if not track then
		return nil
	end

	local weapon = self.Weapon
	local definition = weapon and weapon.Animations and weapon.Animations.Equip

	return self.Controller:PlayAction(track, definition and definition.TransitionTime or 0)
end

function Weapon.Clear(self: Weapon)
	local track = self.EquipTrack
	self.EquipTrack = nil

	if track and track.IsPlaying then
		track:Stop(0)
	end
end

return Weapon
