-- Move animation layer. One track per weapon move, with role "Move:<Name>".
local Combat = {}
Combat.__index = Combat

local ROLE_PREFIX = "Move:"

function Combat.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,

		-- Move name -> track.
		MoveTracks = {},
	}, Combat)

	return self
end

function Combat.role(move_name)
	return ROLE_PREFIX .. move_name
end

function Combat:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load()
end

function Combat:_load()
	table.clear(self.MoveTracks)

	local weapon = self.Weapon
	if not weapon then
		return
	end

	-- Catalog definitions are validated, so every move has an Animation.
	for name, move in pairs(weapon.Moves) do
		self.MoveTracks[name] = self.Controller:Track(Combat.role(name), move.Animation)
	end
end

-- Claims the Action channel for the move's track and returns it, or nil when
-- the move has no loaded track (no animator yet).
function Combat:BeginMove(move_name)
	local track = self.MoveTracks[move_name]
	if not track then
		return nil
	end

	self.Controller:ClaimAction(track)

	return track
end

function Combat:Play(track, transition_time)
	self.Controller:Play(track, transition_time)
end

function Combat:Pause(track)
	self.Controller:Pause(track)
end

function Combat:Resume(track)
	self.Controller:Resume(track)
end

function Combat:StopAction()
	self.Controller:StopAction()
end

function Combat:Clear()
	for _, track in pairs(self.MoveTracks) do
		if track.IsPlaying then
			track:Stop(0)
		end
	end

	table.clear(self.MoveTracks)
	self.Weapon = nil
end

return Combat
