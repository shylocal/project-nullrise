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
	if self.Controller:IsActionPlaying() then
		return
	end

	local track

	if self.Sprinting and self.SprintTrack then
		track = self.SprintTrack
	else
		track = self.IdleTrack
	end

	if not track then
		return
	end

	local other = track == self.SprintTrack and self.IdleTrack or self.SprintTrack
	if other then
		other:Stop()
	end

	if not track.IsPlaying then
		local definition

		if track == self.SprintTrack then
			definition = self.Weapon
				and self.Weapon.Animations
				and self.Weapon.Animations.Sprint
		else
			definition = self.Weapon
				and self.Weapon.Animations
				and self.Weapon.Animations.Idle
		end

		track:Play(definition and definition.TransitionTime or 0)
	end
end

function Movement:Clear()
	self.Weapon = nil
	self.IdleTrack = nil
	self.SprintTrack = nil
end


return Movement
