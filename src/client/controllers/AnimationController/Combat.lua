-- Attack and charge animation layer. Roles are "Attack<n>" and "Charge".
local Combat = {}
Combat.__index = Combat

function Combat.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,

		AttackTracks = {},
		ChargeTrack = nil,
	}, Combat)

	return self
end

function Combat:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load()
end

function Combat:_load()
	table.clear(self.AttackTracks)
	self.ChargeTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return
	end

	-- Catalog definitions are validated, so Attacks is always a dense array.
	for attack_index, attack in ipairs(weapon.Attacks) do
		if attack.Animation then
			self.AttackTracks[attack_index] = self.Controller:Track("Attack" .. attack_index, attack.Animation)
		end
	end

	if weapon.Charge and weapon.Charge.Animation then
		self.ChargeTrack = self.Controller:Track("Charge", weapon.Charge.Animation)
	end
end

function Combat:BeginAttack(attack_index)
	local track = self.AttackTracks[attack_index]
	if not track then
		return nil
	end

	self.Controller:ClaimAction(track)

	return track
end

function Combat:BeginCharge()
	local track = self.ChargeTrack
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
	for _, track in pairs(self.AttackTracks) do
		if track.IsPlaying then
			track:Stop(0)
		end
	end
	if self.ChargeTrack and self.ChargeTrack.IsPlaying then
		self.ChargeTrack:Stop(0)
	end

	table.clear(self.AttackTracks)
	self.ChargeTrack = nil
	self.Weapon = nil
end

return Combat
