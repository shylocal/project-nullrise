--!strict
-- Locomotion layer: the weapon's Idle and Sprint tracks.
local Types = require(script.Parent.Types)

type Track = Types.Track

type MovementFields = {
	Controller: Types.Host,
	Weapon: Types.WeaponDefinition?,
	Sprinting: boolean,
	IdleTrack: Track?,
	SprintTrack: Track?,
}

local Movement = {}
Movement.__index = Movement

export type Movement = typeof(setmetatable({} :: MovementFields, Movement))

function Movement.new(animation_controller: Types.Host): Movement
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		Sprinting = false,

		IdleTrack = nil,
		SprintTrack = nil,
	} :: MovementFields, Movement)

	return self
end

function Movement.SetWeapon(self: Movement, weapon: Types.WeaponDefinition?)
	self.Weapon = weapon
	self:_load()
end

function Movement.SetSprinting(self: Movement, sprinting: boolean)
	if self.Sprinting == sprinting then
		return
	end

	self.Sprinting = sprinting
	self:Update()
end

function Movement._load(self: Movement)
	self.IdleTrack = nil
	self.SprintTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return
	end

	self.IdleTrack = self.Controller:Track("Idle", weapon.Animations and weapon.Animations.Idle)
	self.SprintTrack = self.Controller:Track("Sprint", weapon.Animations and weapon.Animations.Sprint)

	self:Update()
end

function Movement.Update(self: Movement)
	local idle_track = self.IdleTrack
	local weapon = self.Weapon

	if idle_track and not idle_track.IsPlaying then
		local definition = weapon and weapon.Animations and weapon.Animations.Idle

		idle_track:Play(definition and definition.TransitionTime or 0)
	end

	local sprint_track = self.SprintTrack
	local channels = self.Controller.Channels

	if not sprint_track then
		channels.Locomotion = idle_track
		return
	end

	if self.Sprinting then
		if not sprint_track.IsPlaying then
			local definition = weapon and weapon.Animations and weapon.Animations.Sprint

			sprint_track:Play(definition and definition.TransitionTime or 0)
		end
		channels.Locomotion = sprint_track
	else
		if sprint_track.IsPlaying then
			sprint_track:Stop()
		end
		channels.Locomotion = idle_track
	end
end

function Movement.Clear(self: Movement)
	local idle_track = self.IdleTrack
	local sprint_track = self.SprintTrack

	self.IdleTrack = nil
	self.SprintTrack = nil
	self.Weapon = nil

	if idle_track then
		idle_track:Stop(0)
	end

	if sprint_track then
		sprint_track:Stop(0)
	end
end

return Movement
