--!strict
-- Per-character arbiter: controllers hold leases on activities (Hang, Vault,
-- Attack, ...) and ask whether an action may start. Which actions an activity
-- blocks comes from the injected policy (CharacterState.Policy). Also owns one
-- HumanoidOverrides stack per Humanoid so every controller layers Humanoid
-- property changes through the same stacks.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.packages.Signal)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local HumanoidOverrides = require(script.HumanoidOverrides)

export type Activity = "Attack" | "AttackRooted" | "Hang" | "Mantle" | "Vault" | "TopHop" | "Stunned"
export type Action = "Attack" | "Charge" | "Sprint" | "Vault" | "Grab"
export type Policy = { [string]: { string } }
export type HumanoidOverrides = HumanoidOverrides.HumanoidOverrides
export type Handle = HumanoidOverrides.Handle
type Signal = typeof(Signal.new())

-- Fixed order used to report the first blocking activity deterministically.
local ACTIVITIES: { string } = { "Attack", "AttackRooted", "Hang", "Mantle", "Vault", "TopHop", "Stunned" }
local ACTIONS: { [string]: boolean } = { Attack = true, Charge = true, Sprint = true, Vault = true, Grab = true }

local CharacterState = {}
CharacterState.__index = CharacterState

local Lease = {}
Lease.__index = Lease

export type Lease = typeof(setmetatable(
	{} :: {
		-- Whoever acquired the lease (a controller); only kept for debugging.
		Owner: any,
		Activity: string,
		_state: CharacterState,
		_released: boolean,
	},
	Lease
))

export type CharacterState = typeof(setmetatable(
	{} :: {
		-- Fires (activity: Activity, active: boolean) when an activity starts or ends.
		Changed: Signal,
		_blocks: { [string]: { [string]: boolean } },
		_counts: { [string]: number },
		_leases: { [Lease]: boolean },
		_overrides: { [Humanoid]: HumanoidOverrides },
		_destroyed: boolean,
	},
	CharacterState
))

local function validate_policy(policy: any): { [string]: { [string]: boolean } }
	if type(policy) ~= "table" then
		error("CharacterState.new: policy must be a table", 3)
	end
	local blocks: { [string]: { [string]: boolean } } = {}
	for _, activity in ACTIVITIES do
		local actions = policy[activity]
		if type(actions) ~= "table" then
			error(("CharacterState.new: policy is missing activity '%s'"):format(activity), 3)
		end
		local set: { [string]: boolean } = {}
		for _, action in actions do
			if not ACTIONS[action] then
				error(("CharacterState.new: policy.%s has unknown action '%s'"):format(activity, tostring(action)), 3)
			end
			set[action] = true
		end
		blocks[activity] = set
	end
	for activity in policy do
		if blocks[activity] == nil then
			error(("CharacterState.new: policy has unknown activity '%s'"):format(tostring(activity)), 3)
		end
	end
	return blocks
end

function CharacterState.new(deps: { policy: Policy }): CharacterState
	Deps.check(deps, "CharacterState", { "policy" })
	local self = setmetatable({
		Changed = Signal.new(),
		_blocks = validate_policy(deps.policy),
		_counts = {},
		_leases = {},
		_overrides = {},
		_destroyed = false,
	}, CharacterState)
	for _, activity in ACTIVITIES do
		self._counts[activity] = 0
	end
	return self
end

function CharacterState.Acquire(self: CharacterState, owner: any, activity: Activity): Lease
	if self._destroyed then
		error("CharacterState:Acquire called after Destroy", 2)
	end
	local count = self._counts[activity]
	if count == nil then
		error(("CharacterState:Acquire: unknown activity '%s'"):format(tostring(activity)), 2)
	end

	local lease = setmetatable({
		Owner = owner,
		Activity = activity :: string,
		_state = self,
		_released = false,
	}, Lease)
	self._leases[lease] = true
	self._counts[activity] = count + 1
	if count == 0 then
		self.Changed:Fire(activity, true)
	end
	return lease
end

function CharacterState.IsActive(self: CharacterState, activity: Activity): boolean
	local count = self._counts[activity]
	if count == nil then
		error(("CharacterState:IsActive: unknown activity '%s'"):format(tostring(activity)), 2)
	end
	return count > 0
end

-- Returns false and the first active activity (in ACTIVITIES order) that
-- blocks the action.
function CharacterState.CanStart(self: CharacterState, action: Action): (boolean, Activity?)
	if not ACTIONS[action] then
		error(("CharacterState:CanStart: unknown action '%s'"):format(tostring(action)), 2)
	end
	for _, activity in ACTIVITIES do
		if self._counts[activity] > 0 and self._blocks[activity][action] then
			return false, activity :: Activity
		end
	end
	return true, nil
end

-- One override stack per Humanoid, shared by every controller of this character.
function CharacterState.Overrides(self: CharacterState, humanoid: Humanoid): HumanoidOverrides
	if self._destroyed then
		error("CharacterState:Overrides called after Destroy", 2)
	end
	local overrides = self._overrides[humanoid]
	if not overrides then
		overrides = HumanoidOverrides.new(humanoid)
		self._overrides[humanoid] = overrides
	end
	return overrides
end

function CharacterState._release(self: CharacterState, lease: Lease)
	if not self._leases[lease] then
		return
	end
	self._leases[lease] = nil
	local count = self._counts[lease.Activity] - 1
	self._counts[lease.Activity] = count
	if count == 0 and not self._destroyed then
		self.Changed:Fire(lease.Activity, false)
	end
end

function CharacterState.Destroy(self: CharacterState)
	if self._destroyed then
		return
	end
	local leases = {}
	for lease in self._leases do
		table.insert(leases, lease)
	end
	for _, lease in leases do
		lease:Release()
	end
	for _, overrides in self._overrides do
		overrides:Destroy()
	end
	table.clear(self._overrides)
	self._destroyed = true
	self.Changed:Destroy()
end

function Lease.Release(self: Lease)
	if self._released then
		return
	end
	self._released = true
	local state = self._state
	state:_release(self)
end

function Lease.IsReleased(self: Lease): boolean
	return self._released
end

return CharacterState
