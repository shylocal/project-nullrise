--!strict
-- Time source and delayed callbacks behind one seam, so services can be driven
-- by a fake clock in specs. Fields are plain closures: call `scheduler.clock()`
-- and `scheduler.after(seconds, fn)` without `self`.
export type Cancel = () -> ()
export type Scheduler = {
	clock: () -> number,
	after: (seconds: number, fn: () -> ()) -> Cancel,
}

local Scheduler = {}

local function after(seconds: number, fn: () -> ()): Cancel
	local thread = task.delay(seconds, fn)
	return function()
		-- Cancelling a finished or currently running thread errors; either
		-- way the callback can no longer run, so the error is irrelevant.
		pcall(task.cancel, thread)
	end
end

function Scheduler.real(): Scheduler
	return {
		clock = os.clock,
		after = after,
	}
end

return table.freeze(Scheduler)
