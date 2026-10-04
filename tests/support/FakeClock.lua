--!strict
-- Deterministic stand-in for Scheduler.real(). Time only moves on advance();
-- callbacks run in due order, with `now` set to each callback's due time
-- first, including callbacks scheduled by other callbacks inside the window.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

type Task = {
	DueAt: number,
	Sequence: number,
	Fn: () -> (),
}

type FakeClockFields = {
	now: () -> number,
	after: (seconds: number, fn: () -> ()) -> () -> (),
	_tasks: { Task },
	_set_now: (value: number) -> (),
}

local FakeClock = {}
FakeClock.__index = FakeClock

export type FakeClock = typeof(setmetatable({} :: FakeClockFields, FakeClock))

function FakeClock.new(start: number?): FakeClock
	local now = start or 0
	local sequence = 0
	local tasks: { Task } = {}

	local function get_now(): number
		return now
	end

	local function after(seconds: number, fn: () -> ()): () -> ()
		assert(type(seconds) == "number" and seconds == seconds, "FakeClock.after: seconds must be a number")
		sequence += 1
		local entry: Task = {
			DueAt = now + math.max(seconds, 0),
			Sequence = sequence,
			Fn = fn,
		}
		table.insert(tasks, entry)

		return function()
			local index = table.find(tasks, entry)
			if index then
				table.remove(tasks, index)
			end
		end
	end

	local fields: FakeClockFields = {
		now = get_now,
		after = after,
		_tasks = tasks,
		_set_now = function(value: number)
			now = value
		end,
	}

	return setmetatable(fields, FakeClock)
end

function FakeClock.scheduler(self: FakeClock): Scheduler.Scheduler
	return {
		clock = self.now,
		after = self.after,
	}
end

local function next_due(tasks: { Task }, limit: number): number?
	local best: Task? = nil
	local best_index: number? = nil
	for index, entry in tasks do
		if entry.DueAt <= limit then
			if not best
				or entry.DueAt < best.DueAt
				or (entry.DueAt == best.DueAt and entry.Sequence < best.Sequence) then
				best = entry
				best_index = index
			end
		end
	end
	return best_index
end

function FakeClock.advance(self: FakeClock, dt: number): ()
	assert(type(dt) == "number" and dt >= 0, "FakeClock.advance: dt must be a non-negative number")
	local target = self.now() + dt

	while true do
		local index = next_due(self._tasks, target)
		if not index then
			break
		end

		local entry = table.remove(self._tasks, index) :: Task
		self._set_now(math.max(self.now(), entry.DueAt))
		entry.Fn()
	end

	self._set_now(target)
end

function FakeClock.pending(self: FakeClock): number
	return #self._tasks
end

return FakeClock
