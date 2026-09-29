-- Small, pure Vector3 helpers shared by client and server code.
local Vector = {}

-- Remove vertical movement while preserving the original horizontal direction.
function Vector.flatten(value)
	return Vector3.new(value.X, 0, value.Z)
end

return Vector
