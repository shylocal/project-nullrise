local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(character)
	local self = setmetatable({
		Character = character,
		Trove = Trove.new(),
		AnimationTrove = Trove.new(),

		Humanoid = nil,
		Animator = nil,
		Weapon = nil,

		Tracks = {},
		AttackTracks = {},
		ActionTrack = nil,
		Sprinting = false,
	}, AnimationController)

	self:_start()

	return self
end

function AnimationController:_start()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		self:_set_humanoid(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child)
				if child:IsA("Humanoid") then
					self:_set_humanoid(child)
				end
			end
		)
	end
end

function AnimationController:_set_humanoid(humanoid)
	if self.Humanoid == humanoid then
		return
	end

	self.Humanoid = humanoid

	local animator = humanoid:FindFirstChildOfClass("Animator")

	if animator then
		self:_set_animator(animator)
	else
		self.Trove:Connect(
			humanoid.ChildAdded,
			function(child)
				if child:IsA("Animator") then
					self:_set_animator(child)
				end
			end
		)
	end
end

function AnimationController:_set_animator(animator)
	if self.Animator == animator then
		return
	end

	self.Animator = animator

	if self.Weapon then
		self:_load_weapon()
	end
end

function AnimationController:_load_weapon()
	self:_clear_tracks()

	local animator = self.Animator
	local weapon = self.Weapon

	if not animator or animator.Parent == nil or not weapon then
		return
	end

	for name, definition in pairs(weapon.Animations or {}) do
		self.Tracks[name] = self:_load_track(animator, definition)
	end

	for attack_index, attack in pairs(weapon.Attacks or {}) do
		if attack.Animation then
			self.AttackTracks[attack_index] = self:_load_track(animator, attack.Animation)
		end
	end
end

function AnimationController:_load_track(animator, definition)
	local animation = Instance.new("Animation")
	animation.AnimationId = definition.Id

	local track = animator:LoadAnimation(animation)
	track.Priority = definition.Priority
	track.Looped = definition.Looped

	self.AnimationTrove:Add(animation)
	self.AnimationTrove:Add(track)

	self.AnimationTrove:Connect(
		track.Ended,
		function()
			if self.ActionTrack == track then
				self.ActionTrack = nil
				self:_update_movement_animation()
			end
		end
	)

	return track
end

function AnimationController:_clear_tracks()
	local action_track = self.ActionTrack
	self.ActionTrack = nil

	if action_track then
		action_track:Stop(0)
	end

	self.AnimationTrove:Destroy()
	self.AnimationTrove = Trove.new()

	table.clear(self.Tracks)
	table.clear(self.AttackTracks)
end

function AnimationController:_claim_action(track)
	local current = self.ActionTrack

	self.ActionTrack = track

	if current and current ~= track then
		current:Stop(0)
	end

	track.TimePosition = 0
	track:AdjustSpeed(1)
end

function AnimationController:_play_movement_animation()
	if self.ActionTrack then
		return
	end

	local track

	if self.Sprinting and self.Tracks.Sprint then
		track = self.Tracks.Sprint
	else
		track = self.Tracks.Idle
	end

	if not track then
		return
	end

	local other = self.Sprinting and self.Tracks.Idle or self.Tracks.Sprint
	if other then
		other:Stop()
	end

	if not track.IsPlaying then
		local definition = self.Sprinting
			and self.Weapon
			and self.Weapon.Animations
			and self.Weapon.Animations.Sprint
			or self.Weapon
			and self.Weapon.Animations
			and self.Weapon.Animations.Idle

		track:Play(definition and definition.TransitionTime or 0)
	end
end

function AnimationController:_play_action(track, transition_time)
	if not track then
		return nil
	end

	self:_claim_action(track)
	track:Play(transition_time or 0)

	return track
end

function AnimationController:SetWeapon(weapon)
	self.Weapon = weapon
	self:_load_weapon()
end

function AnimationController:SetSprinting(sprinting)
	if self.Sprinting == sprinting then
		return
	end

	self.Sprinting = sprinting
	self:_update_movement_animation()
end

function AnimationController:PlayEquip()
	local track = self.Tracks.Equip

	if not track then
		self:_update_movement_animation()
		return nil
	end

	local definition = self.Weapon
		and self.Weapon.Animations
		and self.Weapon.Animations.Equip

	return self:_play_action(track, definition and definition.TransitionTime or 0)
end

function AnimationController:BeginAttack(attack_index)
	local track = self.AttackTracks[attack_index]
	if not track then
		return nil
	end

	self:_claim_action(track)
	return track
end

function AnimationController:BeginCharge()
	local track = self.Tracks.Charge
	if not track then
		return nil
	end

	self:_claim_action(track)
	return track
end

function AnimationController:Play(track, transition_time)
	if not track then
		return
	end

	track:Play(transition_time or 0)
end

function AnimationController:Pause(track)
	if self.ActionTrack == track then
		track:AdjustSpeed(0)
	end
end

function AnimationController:Resume(track)
	if self.ActionTrack == track then
		track:AdjustSpeed(1)
	end
end

function AnimationController:StopAction()
	local track = self.ActionTrack
	self.ActionTrack = nil

	if track then
		track:Stop(0)
	end

	self:_update_movement_animation()
end

function AnimationController:Destroy()
	self:_clear_tracks()
	self.Trove:Destroy()
end

return AnimationController
