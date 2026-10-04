-- Character animation owner. Tracks come from one TrackCache per Animator and
-- outlive weapon swaps; SetWeapon only stops the previous weapon's tracks and
-- remaps roles. Exclusive playback is arbitrated through channels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local TrackCache = require(script.TrackCache)
local Movement = require(script.Movement)
local Weapon = require(script.Weapon)
local Combat = require(script.Combat)

local CHANNELS = { Locomotion = true, Action = true, Traversal = true }

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(deps)
	Deps.check(deps, "AnimationController", { "character" })

	local self = setmetatable({
		Character = deps.character,
		Trove = Trove.new(),

		Humanoid = nil,
		Animator = nil,
		Cache = nil,
		-- Owns per-track connections; replaced together with the cache.
		CacheTrove = nil,
		-- Tracks whose Ended handler is already connected (once per track).
		KnownTracks = {},
		EquippedWeapon = nil,

		Channels = {
			Locomotion = nil,
			Action = nil,
			Traversal = nil,
		},

		Movement = nil,
		Weapon = nil,
		Combat = nil,
		_destroyed = false,
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

	self:_stop_tracks()
	self:_destroy_cache()

	self.Animator = animator
	self.Cache = TrackCache.new(animator)
	self.CacheTrove = Trove.new()

	self:_apply_weapon(self.EquippedWeapon)
end

function AnimationController:_destroy_cache()
	local cache = self.Cache
	local cache_trove = self.CacheTrove
	self.Cache = nil
	self.CacheTrove = nil
	table.clear(self.KnownTracks)

	if cache_trove then
		cache_trove:Destroy()
	end
	if cache then
		cache:Destroy()
	end
end

-- Returns the cached track for a role, or nil when there is no usable Animator.
function AnimationController:Track(role, definition)
	local animator = self.Animator
	local cache = self.Cache

	if not cache or not animator or animator.Parent == nil or not definition or typeof(definition.Id) ~= "string" then
		return nil
	end

	local track = cache:Get(role, definition)

	if not self.KnownTracks[track] then
		self.KnownTracks[track] = true
		self.CacheTrove:Connect(
			track.Ended,
			function()
				-- A stopped track can be re-claimed before its Ended arrives;
				-- only a track that is really done releases its channel.
				if track.IsPlaying then
					return
				end
				for channel, current in pairs(self.Channels) do
					if current == track and channel ~= "Locomotion" then
						self.Channels[channel] = nil
					end
				end
			end
		)
	end

	return track
end

-- Makes `track` the exclusive track of `channel`, stopping the previous one.
function AnimationController:Claim(channel, track)
	assert(CHANNELS[channel] and channel ~= "Locomotion", "AnimationController:Claim: channel must be Action or Traversal")

	local current = self.Channels[channel]

	if current and current ~= track then
		current:Stop(0)
	end

	self.Channels[channel] = track
end

function AnimationController:ClaimAction(track)
	if not track then
		return
	end

	self:Claim("Action", track)

	track.TimePosition = 0
	track:AdjustSpeed(1)
end

-- TransitionTime is optional in weapon animation definitions (see
-- shared/weapons/Validator); nil means the track plays with no blend.
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
	if self.Channels.Action == track then
		track:AdjustSpeed(0)
	end
end

function AnimationController:Resume(track)
	if self.Channels.Action == track then
		track:AdjustSpeed(1)
	end
end

function AnimationController:IsActionPlaying()
	return self.Channels.Action ~= nil
end

function AnimationController:StopAction()
	local track = self.Channels.Action
	self.Channels.Action = nil

	if track then
		track:Stop(0)
	end

	self.Movement:Update()
end

function AnimationController:SetWeapon(weapon)
	self.EquippedWeapon = weapon
	self:_stop_tracks()
	self:_apply_weapon(weapon)
end

function AnimationController:_apply_weapon(weapon)
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

-- Stops every track of the current weapon without destroying any of them.
function AnimationController:_stop_tracks()
	for channel, track in pairs(self.Channels) do
		self.Channels[channel] = nil
		track:Stop(0)
	end

	self.Weapon:Clear()
	self.Movement:Clear()
	self.Combat:Clear()
end

function AnimationController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self:_stop_tracks()
	self.Trove:Destroy()
	self:_destroy_cache()
	self.Animator = nil
	self.Humanoid = nil
end

return AnimationController
