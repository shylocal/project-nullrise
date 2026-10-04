--!strict
-- AnimationTrack stand-in. Nothing advances on its own: specs drive markers
-- with FireMarker and completion with Finish (or Stop).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.packages.Signal)

export type Options = {
	Length: number?,
	Markers: { [string]: number }?,
}

local FakeAnimationTrack = {}
FakeAnimationTrack.__index = FakeAnimationTrack

function FakeAnimationTrack.new(opts: Options?): any
	local options: Options = opts or {}
	return setmetatable({
		Animation = nil :: any,
		IsPlaying = false,
		TimePosition = 0,
		Speed = 1,
		WeightTarget = 1,
		Looped = false,
		Priority = Enum.AnimationPriority.Core,
		Length = options.Length or 1,
		Markers = options.Markers or {},
		PlayCount = 0,
		StopCount = 0,
		Destroyed = false,
		Ended = Signal.new(),
		Stopped = Signal.new(),
		_marker_signals = {} :: { [string]: any },
	}, FakeAnimationTrack)
end

function FakeAnimationTrack.Play(self: any, _fade: number?, weight: number?, speed: number?)
	self.IsPlaying = true
	self.TimePosition = 0
	self.PlayCount += 1
	if weight ~= nil then
		self.WeightTarget = weight
	end
	if speed ~= nil then
		self.Speed = speed
	end
end

-- Fading is instantaneous: Stop fires Stopped and then Ended.
function FakeAnimationTrack.Stop(self: any, _fade: number?)
	self.StopCount += 1
	if not self.IsPlaying then
		return
	end
	self.IsPlaying = false
	self.Stopped:Fire()
	self.Ended:Fire()
end

function FakeAnimationTrack.AdjustSpeed(self: any, speed: number)
	self.Speed = speed
end

function FakeAnimationTrack.GetMarkerReachedSignal(self: any, name: string): any
	local signal = self._marker_signals[name]
	if not signal then
		signal = Signal.new()
		self._marker_signals[name] = signal
	end
	return signal
end

-- Moves TimePosition to the marker's configured time (if any) and fires it.
function FakeAnimationTrack.FireMarker(self: any, name: string, parameter: string?)
	local time_position = self.Markers[name]
	if time_position ~= nil then
		self.TimePosition = time_position
	end
	local signal = self._marker_signals[name]
	if signal then
		signal:Fire(parameter)
	end
end

-- Plays the track to its end: IsPlaying = false, then Stopped and Ended.
function FakeAnimationTrack.Finish(self: any)
	self.IsPlaying = false
	self.TimePosition = self.Length
	self.Stopped:Fire()
	self.Ended:Fire()
end

function FakeAnimationTrack.Destroy(self: any)
	self.Destroyed = true
	self.IsPlaying = false
	self.Ended:DisconnectAll()
	self.Stopped:DisconnectAll()
	for _, signal in self._marker_signals do
		signal:DisconnectAll()
	end
end

-- Animator stand-in: LoadAnimation returns a fresh FakeTrack and counts loads.
function FakeAnimationTrack.animator(opts: Options?): any
	local animator = {
		Loads = 0,
		Tracks = {} :: { any },
	}

	function animator.LoadAnimation(self: any, animation: any): any
		self.Loads += 1
		local track = FakeAnimationTrack.new(opts)
		track.Animation = animation
		table.insert(self.Tracks, track)
		return track
	end

	return animator
end

return FakeAnimationTrack
