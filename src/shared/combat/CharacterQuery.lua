--!strict
-- Resolves any instance (a body part, an accessory, a nested weapon part) to
-- the character Model that owns it. Used by the client hitbox, server hit
-- validation and line-of-sight so every side agrees on what a "character" is.
local CharacterQuery = {}

local function nearest_model(instance: Instance): Model?
	if instance:IsA("Model") then
		return instance
	end
	return instance:FindFirstAncestorOfClass("Model")
end

-- Starts at `instance` if it is a Model, otherwise its nearest Model ancestor,
-- and walks up Model ancestors until one has a Humanoid child. Health is not
-- considered. Workspace (a WorldRoot, which is also a Model) is never a
-- character, so the walk stops there.
function CharacterQuery.resolve(instance: Instance?): (Model?, Humanoid?)
	if typeof(instance) ~= "Instance" then
		return nil, nil
	end
	local model = nearest_model(instance :: Instance)
	while model ~= nil and not model:IsA("WorldRoot") do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			return model, humanoid
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

function CharacterQuery.is_alive(humanoid: Humanoid?): boolean
	return humanoid ~= nil and humanoid.Health > 0 and humanoid.Parent ~= nil
end

-- Like resolve, but returns nil, nil when the humanoid is dead or detached.
function CharacterQuery.resolve_alive(instance: Instance?): (Model?, Humanoid?)
	local model, humanoid = CharacterQuery.resolve(instance)
	if model == nil or not CharacterQuery.is_alive(humanoid) then
		return nil, nil
	end
	return model, humanoid
end

return table.freeze(CharacterQuery)
