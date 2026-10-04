--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ShapecastHitbox = require(ReplicatedStorage.packages.ShapecastHitbox)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)

-- (hit character, raycast result, the wielded segment's instance?)
export type OnHit = (hit_character: Model, raycast_result: RaycastResult, segment_instance: Instance?) -> ()

type HitboxFields = {
	Character: Model,
	Shapecast: ShapecastHitbox.Hitbox,
	-- Characters already hit during the current swing.
	HitCharacters: { [Model]: boolean },
}

local Hitbox = {}
Hitbox.__index = Hitbox

export type Hitbox = typeof(setmetatable({} :: HitboxFields, Hitbox))

-- Resolves a raw hit part to the living character it belongs to, or nil for
-- the owner, map geometry and dead humanoids. Nested models (an enemy's
-- weapon) resolve to the character holding them.
function Hitbox.resolve_target(owner: Instance, hit_part: Instance?): Model?
	local target = CharacterQuery.resolve_alive(hit_part)
	if not target or target == owner then
		return nil
	end
	return target
end

function Hitbox.new(character: Model, wielded: Instance, on_hit: OnHit): Hitbox
	local raycast_params = RaycastParams.new()
	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = { character }

	local shapecast = ShapecastHitbox.new(wielded, raycast_params)

	local self = setmetatable({
		Character = character,
		Shapecast = shapecast,
		HitCharacters = {},
	} :: HitboxFields, Hitbox)

	shapecast:OnHit(function(raycast_result: RaycastResult, segment: ShapecastHitbox.Segment?)
		-- Only living characters are forwarded, so walls, props and map
		-- container models never consume the per-target dedupe slot.
		local hit_character = Hitbox.resolve_target(character, raycast_result.Instance)
		if not hit_character or self.HitCharacters[hit_character] then
			return
		end

		self.HitCharacters[hit_character] = true

		on_hit(
			hit_character,
			raycast_result,
			segment and segment.Instance
		)
	end)

	return self
end

-- Hitboxes are reused across swings: each Start begins a fresh per-target
-- dedupe for the new swing.
function Hitbox.Start(self: Hitbox)
	table.clear(self.HitCharacters)
	self.Shapecast:HitStart()
end

function Hitbox.Stop(self: Hitbox)
	if self.Shapecast.Active then
		self.Shapecast:HitStop()
	end
end

function Hitbox.Destroy(self: Hitbox)
	self:Stop()
	table.clear(self.HitCharacters)
	self.Shapecast:Destroy()
end

return Hitbox
