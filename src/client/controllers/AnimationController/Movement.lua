local Movement = {}
Movement.__index = Movement

function Movement.new(animation_controller)
	local self = setmetatable({
		Controller = animation_controller,
		Weapon = nil,
		Sprinting = false,

		IdleTrack = nil,
		SprintTrack = nil,
	}, Movement)

	animation_controller.AnimatorChanged:Connect(function()
		self:_load()
	end)

	return self
end

function Movement:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load()
end

function Movement:SetSprinting(sprinting)
	if self.Sprinting == sprinting then
		return
	end

	self.Sprinting = sprinting
	self:Update()
end

function Movement:_load()
	self.IdleTrack = nil
	self.SprintTrack = nil

	local weapon = self.Weapon
	if not weapon then
		return
	end

	self.IdleTrack = self.Controller:Load(
		weapon.Animations and weapon.Animations.Idle
	)

	self.SprintTrack = self.Controller:Load(
		weapon.Animations and weapon.Animations.Sprint
	)

	self:Update()
end

function Movement:Update()
	local idle_track = self.IdleTrack

	if idle_track and not idle_track.IsPlaying then
		local definition = self.Weapon
			and self.Weapon.Animations
			and self.Weapon.Animations.Idle

		idle_track:Play(definition and definition.TransitionTime or 0)
	end

	local sprint_track = self.SprintTrack
	if not sprint_track then
		return
	end

	if self.Sprinting then
		if not sprint_track.IsPlaying then
			local definition = self.Weapon
				and self.Weapon.Animations
				and self.Weapon.Animations.Sprint

			sprint_track:Play(definition and definition.TransitionTime or 0)
		end
	elseif sprint_track.IsPlaying then
		sprint_track:Stop()
	end
end

function Movement:Clear()
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
