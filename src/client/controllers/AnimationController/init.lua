local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Movement = require(script.Movement)
local Weapon = require(script.Weapon)
local Combat = require(script.Combat)

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(character)
	local self = setmetatable({
		Character = character,
		Trove = Trove.new(),
		AnimationTrove = Trove.new(),

		Humanoid = nil,
		Animator = nil,
		ActionTrack = nil,


		Movement = nil,
		Weapon = nil,
		Combat = nil,
	}, AnimationController)

	self.Movement = Movement.new(self)
	self.Weapon = Weapon.new(self)
	self.Combat = Combat.new(self)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

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

	self.Trove:Connect(
		humanoid.ChildAdded,
		function(child)
			if child:IsA("Animator") then
				self:_set_animator(child)
			end
		end
	)

	local animator = humanoid:FindFirstChildOfClass("Animator")

	if animator then
		self:_set_animator(animator)
	end
end

function AnimationController:_set_animator(animator)
	if self.Animator == animator then
		return
	end

	local weapon = self.Weapon.Weapon

	self:_clear_tracks()

	self.Animator = animator

	self.Movement:SetWeapon(weapon)
	self.Weapon:SetWeapon(weapon)
	self.Combat:SetWeapon(weapon)
end

function AnimationController:Load(definition)
	local animator = self.Animator

	if not animator or animator.Parent == nil or not definition or typeof(definition.Id) ~= "string" then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = definition.Id

	ContentProvider:PreloadAsync({animation})

	local track = animator:LoadAnimation(animation)

	if definition.Priority then
		track.Priority = definition.Priority
	end

	if definition.Looped ~= nil then
		track.Looped = definition.Looped
	end

	self.AnimationTrove:Add(animation)
	self.AnimationTrove:Add(track)

	self.AnimationTrove:Connect(
		track.Ended,
		function()
			if self.ActionTrack == track then
				self.ActionTrack = nil
			end
		end
	)

	return track
end

function AnimationController:ClaimAction(track)
	if not track then
		return
	end

	local current = self.ActionTrack

	if current and current ~= track then
		current:Stop(0)
	end

	self.ActionTrack = track

	track.TimePosition = 0
	track:AdjustSpeed(1)
end

function AnimationController:PlayAction(track, transition_time)
	if not track then
		return nil
	end

	self:ClaimAction(track)
	track:Play(transition_time or 0)

	return track
end

function AnimationController:Play(track, transition_time)
	if track then
		track:Play(transition_time or 0)
	end
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

function AnimationController:IsActionPlaying()
	return self.ActionTrack ~= nil
end

function AnimationController:StopAction()
	local track = self.ActionTrack
	self.ActionTrack = nil

	if track then
		track:Stop(0)
	end

	self.Movement:Update()
end

function AnimationController:SetWeapon(weapon)
	self:_clear_tracks()

	self.Movement:SetWeapon(weapon)
	self.Weapon:SetWeapon(weapon)
	self.Combat:SetWeapon(weapon)
end

function AnimationController:SetSprinting(sprinting)
	self.Movement:SetSprinting(sprinting)
end

function AnimationController:PlayEquip()
	return self.Weapon:PlayEquip()
end

function AnimationController:_clear_tracks()
	local action_track = self.ActionTrack
	self.ActionTrack = nil

	if action_track then
		action_track:Stop(0)
	end

	self.Weapon:Clear()
	self.Movement:Clear()
	self.Combat:Clear()

	self.AnimationTrove:Destroy()
	self.AnimationTrove = Trove.new()
end

function AnimationController:Destroy()
	self:_clear_tracks()
	self.Trove:Destroy()
end

return AnimationController
