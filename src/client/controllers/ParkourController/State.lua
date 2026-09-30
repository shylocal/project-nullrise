-- Owns parkour state transitions and the Humanoid properties temporarily
-- changed by traversal. Spatial queries and movement remain in their modules.
local State = {}

local TRANSITIONS = {
	Grounded = {
		Hanging = true,
		Vaulting = true,
	},
	Hanging = {
		Grounded = true,
		Mantling = true,
	},
	Mantling = {
		Grounded = true,
		Hanging = true,
	},
	Vaulting = {
		Grounded = true,
	},
}

local function read_humanoid_value(humanoid, property)
	if property == "JumpingEnabled" then
		return humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	end
	return humanoid[property]
end

local function write_humanoid_value(humanoid, property, value)
	if property == "JumpingEnabled" then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, value)
	else
		humanoid[property] = value
	end
end

function State.transition(controller, next_state)
	local current_state = controller.State
	if current_state == next_state then
		return true
	end

	local allowed = TRANSITIONS[current_state]
	if not allowed or not allowed[next_state] then
		return false
	end

	controller.State = next_state
	return true
end

function State.capture_humanoid(controller, key, properties)
	local humanoid = controller.Humanoid
	if not humanoid then
		return nil
	end

	local snapshots = controller._humanoidSnapshots
	if not snapshots then
		snapshots = {}
		controller._humanoidSnapshots = snapshots
	end

	local snapshot = snapshots[key]
	if not snapshot or snapshot.Humanoid ~= humanoid then
		snapshot = { Humanoid = humanoid }
		snapshots[key] = snapshot
	end

	for _, property in ipairs(properties) do
		if snapshot[property] == nil then
			snapshot[property] = read_humanoid_value(humanoid, property)
		end
	end

	return snapshot
end

function State.get_humanoid_snapshot(controller, key)
	local snapshots = controller._humanoidSnapshots
	return snapshots and snapshots[key] or nil
end

function State.get_humanoid_value(controller, key, property)
	local snapshot = State.get_humanoid_snapshot(controller, key)
	return snapshot and snapshot[property] or nil
end

function State.restore_humanoid(controller, key, properties)
	local snapshot = State.get_humanoid_snapshot(controller, key)
	if not snapshot then
		return false
	end

	local humanoid = snapshot.Humanoid
	if humanoid and humanoid.Parent then
		for _, property in ipairs(properties or {}) do
			local value = snapshot[property]
			if value ~= nil then
				write_humanoid_value(humanoid, property, value)
			end
			snapshot[property] = nil
		end
	end

	if properties == nil then
		controller._humanoidSnapshots[key] = nil
	else
		local has_saved_values = false
		for property in pairs(snapshot) do
			if property ~= "Humanoid" then
				has_saved_values = true
				break
			end
		end
		if not has_saved_values then
			controller._humanoidSnapshots[key] = nil
		end
	end

	return true
end

return State
