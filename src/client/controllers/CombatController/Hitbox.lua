local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local ShapecastHitbox = require(Packages.ShapecastHitbox)

local Hitbox = {}
Hitbox.__index = Hitbox

function Hitbox.new(character, wielded, on_hit)
	local raycast_params = RaycastParams.new()
	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = {character}

	local shapecast = ShapecastHitbox.new(wielded, raycast_params)

	local self = setmetatable({
		Character = character,
		Shapecast = shapecast,
		HitCharacters = {},
	}, Hitbox)

	shapecast:OnHit(function(raycast_result, segment)
		local hit_part = raycast_result.Instance
		local hit_character = hit_part and hit_part:FindFirstAncestorOfClass("Model")

		if not hit_character or hit_character == character then
			return
		end

		if self.HitCharacters[hit_character] then
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

function Hitbox:Start()
	self.Shapecast:HitStart()
end

function Hitbox:Stop()
	if self.Shapecast.Active then
		self.Shapecast:HitStop()
	end
end

function Hitbox:Destroy()
	self:Stop()
	table.clear(self.HitCharacters)
	self.Shapecast:Destroy()
end

return Hitbox
