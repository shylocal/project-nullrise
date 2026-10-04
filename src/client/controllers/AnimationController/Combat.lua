--!strict
-- Move animation layer. One track per weapon move, with role "Move:<Name>".
local Types = require(script.Parent.Types)

type Track = Types.Track

type CombatFields = {
	Controller: Types.Host,
	Weapon: Types.WeaponDefinition?,
	-- Move name -> track.
	MoveTracks: { [string]: Track },
}

local Combat = {}
Combat.__index = Combat

export type Combat = typeof(setmetatable({} :: CombatFields, Combat))

local ROLE_PREFIX = "Move:"

function Combat.new(animation_controller: Types.Host): Combat
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		MoveTracks = {},
	} :: CombatFields, Combat)

	return self
end

function Combat.role(move_name: string): string
	return ROLE_PREFIX .. move_name
end

function Combat.SetWeapon(self: Combat, weapon: Types.WeaponDefinition?)
	self.Weapon = weapon
	self:_load()
end

function Combat._load(self: Combat)
	table.clear(self.MoveTracks)

	local weapon = self.Weapon
	if not weapon then
		return
	end

	-- Catalog definitions are validated, so every move has an Animation.
	for name, move in pairs(weapon.Moves) do
		local track = self.Controller:Track(Combat.role(name), move.Animation)
		if track then
			self.MoveTracks[name] = track
		end
	end
end

-- Claims the Action channel for the move's track and returns it, or nil when
-- the move has no loaded track (no animator yet).
function Combat.BeginMove(self: Combat, move_name: string): Track?
	local track = self.MoveTracks[move_name]
	if not track then
		return nil
	end

	self.Controller:ClaimAction(track)

	return track
end

function Combat.Play(self: Combat, track: Track?, transition_time: number?)
	self.Controller:Play(track, transition_time)
end

function Combat.Pause(self: Combat, track: Track)
	self.Controller:Pause(track)
end

function Combat.Resume(self: Combat, track: Track)
	self.Controller:Resume(track)
end


function Combat.Clear(self: Combat)
	for _, track in pairs(self.MoveTracks) do
		if track.IsPlaying then
			track:Stop(0)
		end
	end

	table.clear(self.MoveTracks)
	self.Weapon = nil
end

return Combat
