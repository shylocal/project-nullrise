--!strict
-- Per-Animator AnimationTrack cache. Tracks are loaded once per (role, id) and
-- live as long as the Animator's character, so swapping weapons A -> B -> A
-- reuses A's tracks instead of loading them again.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

export type AnimationDef = {
	Id: string,
	Priority: Enum.AnimationPriority,
	Looped: boolean,
	TransitionTime: number?,
	SharedWith: string?,
}

export type Track = AnimationTrack

-- An Animator, or a spec fake that loads fake tracks.
export type AnimatorLike = {
	LoadAnimation: (self: any, animation: Animation) -> Track,
}

export type Preload = { Destroy: () -> () }

type TrackCacheFields = {
	Animator: Animator | AnimatorLike,
	-- "role:id" -> track
	Tracks: { [string]: Track },
	_destroyed: boolean,
}

-- One Animation instance per id for the whole client session.
local animations: { [string]: Animation } = {}

local TrackCache = {}
TrackCache.__index = TrackCache

export type TrackCache = typeof(setmetatable({} :: TrackCacheFields, TrackCache))

function TrackCache.animation(id: string): Animation
	local existing = animations[id]
	if existing then
		return existing
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = id
	animations[id] = animation
	return animation
end

function TrackCache.new(animator: Animator | AnimatorLike): TrackCache
	return setmetatable({
		Animator = animator,
		Tracks = {},
		_destroyed = false,
	} :: TrackCacheFields, TrackCache)
end

-- Priority and Looped are applied on first load only; a role keeps its track
-- for the cache's lifetime.
function TrackCache.Get(self: TrackCache, role: string, def: AnimationDef): Track
	assert(not self._destroyed, "TrackCache:Get called after Destroy")

	local key = role .. ":" .. def.Id
	local cached = self.Tracks[key]
	if cached then
		return cached
	end

	local animator = self.Animator
	local animation = TrackCache.animation(def.Id)
	local track = if typeof(animator) == "Instance"
		then animator:LoadAnimation(animation)
		else animator:LoadAnimation(animation)
	track.Priority = def.Priority
	track.Looped = def.Looped
	self.Tracks[key] = track
	return track
end

function TrackCache.Destroy(self: TrackCache)
	if self._destroyed then
		return
	end
	self._destroyed = true

	for _, track in pairs(self.Tracks) do
		track:Stop(0)
		track:Destroy()
	end
	table.clear(self.Tracks)
end

local function is_animation_def(value: any): boolean
	return typeof(value) == "table"
		and typeof(value.Id) == "string"
		and typeof(value.Priority) == "EnumItem"
end

-- Every AnimationDef reachable from a Catalog definition, deduped by Id. The
-- walk is shape-agnostic so it also covers future definition layouts.
function TrackCache.collect_catalog(): { AnimationDef }
	local defs: { AnimationDef } = {}
	local seen_ids: { [string]: boolean } = {}
	local visited: { [any]: boolean } = {}

	local function visit(value: any)
		if typeof(value) ~= "table" or visited[value] then
			return
		end
		visited[value] = true

		if is_animation_def(value) then
			if not seen_ids[value.Id] then
				seen_ids[value.Id] = true
				table.insert(defs, value)
			end
			return
		end

		for _, child in pairs(value) do
			visit(child)
		end
	end

	for _, definition in ipairs(Catalog.All()) do
		visit(definition)
	end

	return defs
end

-- Preloads the animations in the background. Destroy cancels the preload if it
-- has not started its request yet.
function TrackCache.preload(defs: { AnimationDef }): Preload
	local instances: { Animation } = {}
	for _, def in ipairs(defs) do
		table.insert(instances, TrackCache.animation(def.Id))
	end

	local done = false
	local thread = task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, instances)
		done = true
	end)

	return {
		Destroy = function()
			if not done then
				done = true
				pcall(task.cancel, thread)
			end
		end,
	}
end

return TrackCache
