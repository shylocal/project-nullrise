--!strict
-- Types shared by the AnimationController layers. They live here rather than
-- in init so the layers (which init requires) can name their host without a
-- require cycle.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local TrackCache = require(script.Parent.TrackCache)

export type Track = TrackCache.Track
export type WeaponDefinition = Catalog.WeaponDefinition
export type AnimationDef = TrackCache.AnimationDef

-- The exclusive track of each channel. Locomotion is owned by the Movement
-- layer; Action and Traversal are claimed through Claim.
export type Channels = {
	Locomotion: Track?,
	Action: Track?,
	Traversal: Track?,
}

-- The AnimationController as its layers see it. Method `self` is `any` so the
-- controller's own type satisfies the shape.
export type Host = {
	Channels: Channels,
	Track: (self: any, role: string, definition: AnimationDef?) -> Track?,
	ClaimAction: (self: any, track: Track?) -> (),
	PlayAction: (self: any, track: Track?, transition_time: number?) -> Track?,
	Play: (self: any, track: Track?, transition_time: number?) -> (),
	Pause: (self: any, track: Track) -> (),
	Resume: (self: any, track: Track) -> (),
}

return table.freeze({})
