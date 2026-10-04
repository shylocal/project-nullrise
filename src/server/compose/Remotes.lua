--!strict
-- Typed lookups of the remotes in ReplicatedStorage's remotes folder. A
-- missing or mistyped remote is an error, raised inside the factory that
-- needs it so the Runtime reports which service failed to start.
local Remotes = {}

local function find(folder: Folder, name: string, class_name: string): Instance
	local remote = folder:FindFirstChild(name)
	if remote == nil or not remote:IsA(class_name) then
		error(("%s.%s must be a %s"):format(folder:GetFullName(), name, class_name), 3)
	end
	return remote
end

function Remotes.event(folder: Folder, name: string): RemoteEvent
	return find(folder, name, "RemoteEvent") :: RemoteEvent
end

function Remotes.unreliable(folder: Folder, name: string): UnreliableRemoteEvent
	return find(folder, name, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
end

return table.freeze(Remotes)
