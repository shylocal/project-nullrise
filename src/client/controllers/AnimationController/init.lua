--!strict
-- Character animation owner. Tracks come from one TrackCache per Animator and
-- outlive weapon swaps; SetWeapon only stops the previous weapon's tracks and
-- remaps roles. Exclusive playback is arbitrated through channels.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(script.Parent.Parent.ClientTrove)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Signal = require(ReplicatedStorage.packages.Signal)
local TrackCache = require(script.TrackCache)
local Types = require(script.Types)
local Movement = require(script.Movement)
local Weapon = require(script.Weapon)
local Combat = require(script.Combat)

type Trove = Trove.Trove
type Track = Types.Track
type WeaponDefinition = Types.WeaponDefinition
type Signal = typeof(Signal.new())

export type Channel = "Locomotion" | "Action" | "Traversal"
export type Deps = {
	character: Model,
}

-- The controller as its users and layers see it (a width-subtype of
-- Types.Host). AnimationController.new builds it; its metatable supplies the
-- methods listed at the end.
export type AnimationController = {
	Character: Model,
	Trove: Trove,
	Humanoid: Humanoid?,
	Animator: Animator?,
	Cache: TrackCache.TrackCache?,
	-- Owns per-track connections; replaced together with the cache.
	CacheTrove: Trove?,
	-- Tracks whose Ended handler is already connected (once per track).
	KnownTracks: { [Track]: boolean },
	-- Fires (no arguments) after a replaced Animator's tracks were stopped
	-- and destroyed. Destroying a track disconnects its Ended handlers, so
	-- owners of an in-flight track (an attack) must clean up on this instead.
	CacheReset: Signal,
	EquippedWeapon: WeaponDefinition?,
	Channels: Types.Channels,
	Movement: Movement.Movement,
	Weapon: Weapon.Weapon,
	Combat: Combat.Combat,
	_destroyed: boolean,

	Track: (self: AnimationController, role: string, definition: Types.AnimationDef?) -> Track?,
	Claim: (self: AnimationController, channel: Channel, track: Track) -> (),
	ClaimAction: (self: AnimationController, track: Track?) -> (),
	PlayAction: (self: AnimationController, track: Track?, transition_time: number?) -> Track?,
	Play: (self: AnimationController, track: Track?, transition_time: number?) -> (),
	Pause: (self: AnimationController, track: Track) -> (),
	Resume: (self: AnimationController, track: Track) -> (),

	IsActionPlaying: (self: AnimationController) -> boolean,
	StopAction: (self: AnimationController) -> (),
	SetWeapon: (self: AnimationController, weapon: WeaponDefinition?) -> (),
	SetSprinting: (self: AnimationController, sprinting: boolean) -> (),

	Destroy: (self: AnimationController) -> (),
	_start: (self: AnimationController) -> (),
	_set_humanoid: (self: AnimationController, humanoid: Humanoid) -> (),
	_set_animator: (self: AnimationController, animator: Animator) -> (),
	_destroy_cache: (self: AnimationController) -> (),
	_apply_weapon: (self: AnimationController, weapon: WeaponDefinition?) -> (),
	_stop_tracks: (self: AnimationController) -> (),
}

local CHANNELS: { [string]: boolean } = { Locomotion = true, Action = true, Traversal = true }

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(deps: Deps): AnimationController
	Deps.check(deps, "AnimationController", { "character" })

	-- The metatable supplies the methods AnimationController lists. The
	-- layers are assigned right below, before anything reads them.
	local self: AnimationController = setmetatable({
		Character = deps.character,
		Trove = Trove.new(),

		Humanoid = nil,
		Animator = nil,
		Cache = nil,
		CacheTrove = nil,
		KnownTracks = {},
		CacheReset = Signal.new(),
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
	}, AnimationController) :: any

	self.Movement = Movement.new(self)
	self.Weapon = Weapon.new(self)
	self.Combat = Combat.new(self)
	self.Trove:Add(self.CacheReset)

	local ok, err = pcall(function()
		self:_start()
	end)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function AnimationController._start(self: AnimationController)
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		self:_set_humanoid(humanoid)
	else
		self.Trove:Connect(self.Character.ChildAdded, function(child: Instance)
			if child:IsA("Humanoid") then
				self:_set_humanoid(child)
			end
		end)
	end
end

function AnimationController._set_humanoid(self: AnimationController, humanoid: Humanoid)
	if self.Humanoid == humanoid then
		return
	end

	self.Humanoid = humanoid

	self.Trove:Connect(humanoid.ChildAdded, function(child: Instance)
		if child:IsA("Animator") then
			self:_set_animator(child)
		end
	end)

	local animator = humanoid:FindFirstChildOfClass("Animator")

	if animator then
		self:_set_animator(animator)
	end
end

function AnimationController._set_animator(self: AnimationController, animator: Animator)
	if self.Animator == animator then
		return
	end

	local replaced = self.Cache ~= nil
	self:_stop_tracks()
	self:_destroy_cache()

	self.Animator = animator
	self.Cache = TrackCache.new(animator)
	self.CacheTrove = Trove.new()

	self:_apply_weapon(self.EquippedWeapon)

	if replaced then
		self.CacheReset:Fire()
	end
end

function AnimationController._destroy_cache(self: AnimationController)
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
function AnimationController.Track(self: AnimationController, role: string, definition: Types.AnimationDef?): Track?
	local animator = self.Animator
	local cache = self.Cache
	local cache_trove = self.CacheTrove

	if
		not cache
		or not cache_trove
		or not animator
		or animator.Parent == nil
		or not definition
		or typeof(definition.Id) ~= "string"
	then
		return nil
	end

	local track = cache:Get(role, definition)

	if not self.KnownTracks[track] then
		self.KnownTracks[track] = true
		cache_trove:Connect(track.Ended, function()
			-- A stopped track can be re-claimed before its Ended arrives;
			-- only a track that is really done releases its channel.
			if track.IsPlaying then
				return
			end
			if self.Channels.Action == track then
				self.Channels.Action = nil
			end
			if self.Channels.Traversal == track then
				self.Channels.Traversal = nil
			end
		end)
	end

	return track
end

-- Makes `track` the exclusive track of `channel`, stopping the previous one.
function AnimationController.Claim(self: AnimationController, channel: Channel, track: Track)
	assert(CHANNELS[channel] and channel ~= "Locomotion", "AnimationController:Claim: channel must be Action or Traversal")

	local channels = self.Channels :: { [string]: Track? }
	local current = channels[channel]

	if current and current ~= track then
		current:Stop(0)
	end

	channels[channel] = track
end

function AnimationController.ClaimAction(self: AnimationController, track: Track?)
	if not track then
		return
	end

	self:Claim("Action", track)

	track.TimePosition = 0
	track:AdjustSpeed(1)
end

-- TransitionTime is optional in weapon animation definitions (see
-- shared/weapons/Validator); nil means the track plays with no blend.
function AnimationController.PlayAction(self: AnimationController, track: Track?, transition_time: number?): Track?
	if not track then
		return nil
	end

	self:ClaimAction(track)
	track:Play(transition_time or 0)

	return track
end

function AnimationController.Play(_self: AnimationController, track: Track?, transition_time: number?)
	if track then
		track:Play(transition_time or 0)
	end
end

function AnimationController.Pause(self: AnimationController, track: Track)
	if self.Channels.Action == track then
		track:AdjustSpeed(0)
	end
end

function AnimationController.Resume(self: AnimationController, track: Track)
	if self.Channels.Action == track then
		track:AdjustSpeed(1)
	end
end


function AnimationController.IsActionPlaying(self: AnimationController): boolean
	return self.Channels.Action ~= nil
end

function AnimationController.StopAction(self: AnimationController)
	local track = self.Channels.Action
	self.Channels.Action = nil

	if track then
		track:Stop(0)
	end

	self.Movement:Update()
end

function AnimationController.SetWeapon(self: AnimationController, weapon: WeaponDefinition?)
	self.EquippedWeapon = weapon
	self:_stop_tracks()
	self:_apply_weapon(weapon)
end

function AnimationController._apply_weapon(self: AnimationController, weapon: WeaponDefinition?)
	self.Movement:SetWeapon(weapon)
	self.Weapon:SetWeapon(weapon)
	self.Combat:SetWeapon(weapon)
end

function AnimationController.SetSprinting(self: AnimationController, sprinting: boolean)
	self.Movement:SetSprinting(sprinting)
end


-- Stops every track of the current weapon without destroying any of them.
function AnimationController._stop_tracks(self: AnimationController)
	local channels = self.Channels :: { [string]: Track? }
	for channel, track in pairs(channels) do
		channels[channel] = nil
		if track then
			track:Stop(0)
		end
	end

	self.Weapon:Clear()
	self.Movement:Clear()
	self.Combat:Clear()
end

function AnimationController.Destroy(self: AnimationController)
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
