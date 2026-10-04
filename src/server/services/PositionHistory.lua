--!strict
-- Per-character ring buffer of recent root and bounding-box samples, written
-- once per step for every tracked live character. Used to rewind hit
-- validation to where a target was on the attacker's screen, and as the
-- position source of MovementValidation (Stepped fires after each step's writes).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Signal = require(ReplicatedStorage.packages.Signal)

local Config = require(ReplicatedStorage.shared.config)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local ROOT_PART = Config.World.Names.RootPart

-- Samples are read-only: Latest returns the stored table.
export type Sample = { Time: number, RootCFrame: CFrame, BoxCFrame: CFrame, BoxSize: Vector3 }

type Ring = {
	Samples: { Sample },
	-- Index of the newest sample; 0 when empty.
	Head: number,
	Count: number,
}

export type PositionHistoryDeps = {
	players: any,
	scheduler: Scheduler.Scheduler,
	step: any,
	capacity: number,
}

type PositionHistoryFields = {
	Trove: any,
	Stepped: any,
	Capacity: number,
	_scheduler: Scheduler.Scheduler,
	_tracked: { [Model]: Ring },
	_destroyed: boolean,
}

local PositionHistory = {}
PositionHistory.__index = PositionHistory

export type PositionHistory = typeof(setmetatable({} :: PositionHistoryFields, PositionHistory))

function PositionHistory.new(deps: PositionHistoryDeps): PositionHistory
	Deps.check(deps, "PositionHistory", { "players", "scheduler", "step", "capacity" })
	local capacity = deps.capacity
	if type(capacity) ~= "number" or capacity < 2 or capacity ~= math.floor(capacity) then
		error("PositionHistory.new: capacity must be an integer >= 2", 2)
	end

	local fields: PositionHistoryFields = {
		Trove = Trove.new(),
		Stepped = Signal.new(),
		Capacity = capacity,
		_scheduler = deps.scheduler,
		_tracked = {},
		_destroyed = false,
	}
	local self = setmetatable(fields, PositionHistory)

	self.Trove:Add(self.Stepped)
	self.Trove:Connect(deps.step, function()
		self:_step()
	end)

	deps.players:Register(self, "PositionHistory")

	return self
end

function PositionHistory.OnCharacterAdded(self: PositionHistory, _session: any, character: Model)
	self._tracked[character] = { Samples = {}, Head = 0, Count = 0 }
end

function PositionHistory.OnCharacterRemoving(self: PositionHistory, _session: any, character: Model)
	self._tracked[character] = nil
end

local function live_root(character: Model): BasePart?
	if character.Parent == nil then
		return nil
	end
	if not CharacterQuery.is_alive(character:FindFirstChildOfClass("Humanoid")) then
		return nil
	end
	local root = character:FindFirstChild(ROOT_PART)
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function write(ring: Ring, capacity: number, sample: Sample)
	ring.Head = ring.Head % capacity + 1
	ring.Samples[ring.Head] = sample
	ring.Count = math.min(ring.Count + 1, capacity)
end

function PositionHistory._step(self: PositionHistory)
	if self._destroyed then
		return
	end
	local now = self._scheduler.clock()
	for character, ring in self._tracked do
		local root = live_root(character)
		if root then
			local box_cframe, box_size = character:GetBoundingBox()
			write(ring, self.Capacity, {
				Time = now,
				RootCFrame = root.CFrame,
				BoxCFrame = box_cframe,
				BoxSize = box_size,
			})
		end
	end
	self.Stepped:Fire(now)
end

-- The newest sample, or nil when the character is untracked or was never live.
function PositionHistory.Latest(self: PositionHistory, character: Model): Sample?
	local ring = self._tracked[character]
	if ring == nil or ring.Count == 0 then
		return nil
	end
	return ring.Samples[ring.Head]
end

-- The character's state at time `t`, interpolated between the two samples
-- around it and clamped to the oldest and newest samples.
function PositionHistory.Sample(self: PositionHistory, character: Model, t: number): Sample?
	local ring = self._tracked[character]
	if ring == nil or ring.Count == 0 then
		return nil
	end

	local capacity = self.Capacity
	local samples = ring.Samples
	local newer = samples[ring.Head]
	if t >= newer.Time then
		return newer
	end

	-- Walk from newest to oldest until a sample at or before t.
	local index = ring.Head
	for _ = 2, ring.Count do
		index = (index - 2) % capacity + 1
		local older = samples[index]
		if older.Time <= t then
			local span = newer.Time - older.Time
			local alpha = if span > 0 then (t - older.Time) / span else 1
			return {
				Time = t,
				RootCFrame = older.RootCFrame:Lerp(newer.RootCFrame, alpha),
				BoxCFrame = older.BoxCFrame:Lerp(newer.BoxCFrame, alpha),
				BoxSize = older.BoxSize:Lerp(newer.BoxSize, alpha),
			}
		end
		newer = older
	end

	-- t is before the oldest sample: clamp.
	return newer
end

function PositionHistory.Destroy(self: PositionHistory)
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._tracked)
	self.Trove:Destroy()
end

return PositionHistory
