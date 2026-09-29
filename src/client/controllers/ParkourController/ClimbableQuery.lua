-- Climbable-tag lookup shared by parkour surface queries.
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Config)
local ClimbableQuery = {}

function ClimbableQuery.get_guide(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, Config.ClimbableTag) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ClimbableQuery.is_climbable(instance)
	return ClimbableQuery.get_guide(instance) ~= nil
end

return ClimbableQuery
