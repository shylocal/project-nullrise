--!strict
-- Counts dropped and rejected requests by category, reason and detail (the
-- weapon id for Combat, the action for Network), keeps a decaying per-player
-- suspicion score, and flushes counts to AnalyticsService every FlushInterval.
-- In Studio each non-empty flush also prints a one-line summary.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

export type Category = "Combat" | "Movement" | "Network" | "Lifecycle" | "Data"

export type TelemetryConfig = {
	FlushInterval: number,
	HalfLife: number,
	DefaultWeight: number,
	Weights: { [string]: number },
}

-- Engine boundary: AnalyticsService:LogCustomEvent(player, name, value, fields).
-- `self` is the AnalyticsService instance or a spec fake.
export type AnalyticsLike = {
	LogCustomEvent: (self: any, player: Player, name: string, value: number?, fields: { [string]: string }?) -> (),
}

export type Deps = {
	config: TelemetryConfig,
	scheduler: Scheduler.Scheduler,
	analytics: AnalyticsLike?,
	is_studio: boolean,
}

type Counter = {
	Category: Category,
	Reason: string,
	Detail: string?,
	Count: number,
}

type PlayerCounters = {
	Keys: number,
	Counters: { [string]: Counter },
}

type Suspicion = {
	Value: number,
	At: number,
}

local CATEGORIES: { [string]: boolean } = {
	Combat = true,
	Movement = true,
	Network = true,
	Lifecycle = true,
	Data = true,
}

-- Lifecycle and Data failures are server-side problems, not player behaviour.
local SUSPICION_CATEGORIES: { [string]: boolean } = {
	Combat = true,
	Movement = true,
	Network = true,
}

-- Details can come from client input (an unknown action name). Bound their
-- length and the number of distinct keys per player between flushes so a
-- client cannot grow these tables without limit.
local MAX_DETAIL_LENGTH = 48
local MAX_KEYS_PER_PLAYER = 64
local OVERFLOW_DETAIL = "<overflow>"
local NO_DETAIL = "-"

-- Counts with no player share this key.
local SERVER = newproxy(false)

-- A Player, or SERVER.
type Owner = unknown

type TelemetryFields = {
	_config: TelemetryConfig,
	_scheduler: Scheduler.Scheduler,
	_analytics: AnalyticsLike?,
	_is_studio: boolean,
	_counts: { [Owner]: PlayerCounters },
	_suspicion: { [Player]: Suspicion },
	_cancel_flush: Scheduler.Cancel?,
	_destroyed: boolean,
}

local Telemetry = {}
Telemetry.__index = Telemetry

export type Telemetry = typeof(setmetatable({} :: TelemetryFields, Telemetry))

function Telemetry.new(deps: Deps): Telemetry
	Deps.check(deps, "Telemetry", { "config", "scheduler", "is_studio" })

	local fields: TelemetryFields = {
		_config = deps.config,
		_scheduler = deps.scheduler,
		_analytics = deps.analytics,
		_is_studio = deps.is_studio,
		_counts = {},
		_suspicion = {},
		_cancel_flush = nil,
		_destroyed = false,
	}

	return setmetatable(fields, Telemetry)
end

local function key_of(category: string, reason: string, detail: string?): string
	return ("%s.%s.%s"):format(category, reason, detail or NO_DETAIL)
end

local function clean_detail(detail: string?): string?
	if detail == nil then
		return nil
	end
	local text = tostring(detail)
	if #text > MAX_DETAIL_LENGTH then
		text = text:sub(1, MAX_DETAIL_LENGTH)
	end
	return text
end

function Telemetry._decayed(self: Telemetry, suspicion: Suspicion, now: number): number
	local elapsed = math.max(now - suspicion.At, 0)
	return suspicion.Value * 0.5 ^ (elapsed / self._config.HalfLife)
end

function Telemetry._weight(self: Telemetry, reason: string): number
	local weight = self._config.Weights[reason]
	if weight == nil then
		-- DefaultWeight is the documented weight of unlisted reasons.
		return self._config.DefaultWeight
	end
	return weight
end

function Telemetry.Count(self: Telemetry, player: Player?, category: Category, reason: string, detail: string?): ()
	if not CATEGORIES[category] then
		error(("Telemetry:Count: unknown category %s"):format(tostring(category)), 2)
	end
	if type(reason) ~= "string" or reason == "" then
		error("Telemetry:Count: reason must be a non-empty string", 2)
	end

	local owner: Owner = if player ~= nil then player else SERVER
	local counters = self._counts[owner]
	if not counters then
		counters = { Keys = 0, Counters = {} }
		self._counts[owner] = counters
	end

	local clean = clean_detail(detail)
	local key = key_of(category, reason, clean)
	local counter = counters.Counters[key]
	if not counter and counters.Keys >= MAX_KEYS_PER_PLAYER then
		clean = OVERFLOW_DETAIL
		key = key_of(category, reason, clean)
		counter = counters.Counters[key]
	end
	if not counter then
		counter = { Category = category, Reason = reason, Detail = clean, Count = 0 }
		counters.Counters[key] = counter
		counters.Keys += 1
	end
	counter.Count += 1

	if player ~= nil and SUSPICION_CATEGORIES[category] then
		local now = self._scheduler.clock()
		local suspicion = self._suspicion[player]
		if suspicion then
			suspicion.Value = self:_decayed(suspicion, now) + self:_weight(reason)
			suspicion.At = now
		else
			self._suspicion[player] = { Value = self:_weight(reason), At = now }
		end
	end
end

function Telemetry.GetSuspicion(self: Telemetry, player: Player): number
	local suspicion = self._suspicion[player]
	if not suspicion then
		return 0
	end
	return self:_decayed(suspicion, self._scheduler.clock())
end

-- Totals since the last flush across every player, keyed
-- "<category>.<reason>.<detail or '-'>".
function Telemetry.Snapshot(self: Telemetry): { [string]: number }
	local totals: { [string]: number } = {}
	for _, counters in self._counts do
		for key, counter in counters.Counters do
			totals[key] = (totals[key] or 0) + counter.Count
		end
	end
	return totals
end

function Telemetry._log(self: Telemetry, owner: Owner, counter: Counter)
	local analytics = self._analytics
	if not analytics or owner == SERVER then
		return
	end
	-- Every owner other than SERVER is the Player that Count was given.
	local player = owner :: Player

	local ok, err = pcall(function()
		-- String field names are the documented custom-field keys.
		analytics:LogCustomEvent(player, "Reject_" .. counter.Category, counter.Count, {
			CustomField01 = counter.Reason,
			CustomField02 = counter.Detail or NO_DETAIL,
		})
	end)
	if not ok and self._is_studio then
		warn(("[Telemetry] LogCustomEvent failed: %s"):format(tostring(err)))
	end
end

function Telemetry.Flush(self: Telemetry): ()
	local counts = self._counts
	self._counts = {}

	for player, counters in counts do
		for _, counter in counters.Counters do
			if counter.Count > 0 then
				self:_log(player, counter)
			end
		end
	end

	-- Suspicion of players who already left is no longer useful.
	for player in self._suspicion do
		if player.Parent == nil then
			self._suspicion[player] = nil
		end
	end

	if self._is_studio then
		local totals: { [string]: number } = {}
		for _, counters in counts do
			for key, counter in counters.Counters do
				totals[key] = (totals[key] or 0) + counter.Count
			end
		end

		local keys = {}
		for key in totals do
			table.insert(keys, key)
		end
		if #keys > 0 then
			table.sort(keys)
			local parts = table.create(#keys)
			for _, key in keys do
				table.insert(parts, ("%s=%d"):format(key, totals[key]))
			end
			print("[Telemetry] " .. table.concat(parts, " "))
		end
	end
end

function Telemetry._schedule(self: Telemetry)
	if self._destroyed then
		return
	end
	self._cancel_flush = self._scheduler.after(self._config.FlushInterval, function()
		self._cancel_flush = nil
		if self._destroyed then
			return
		end
		local ok, err = pcall(function()
			self:Flush()
		end)
		if not ok then
			warn(("[Telemetry] flush failed: %s"):format(tostring(err)))
		end
		self:_schedule()
	end)
end

function Telemetry.Start(self: Telemetry): ()
	if self._cancel_flush or self._destroyed then
		return
	end
	self:_schedule()
end

-- Logs a leaving player's unflushed counts right away (the player cannot be
-- logged against after it is gone), keeps them in the server totals for
-- Snapshot and the Studio summary, and drops the player's suspicion.
function Telemetry.Forget(self: Telemetry, player: Player): ()
	self._suspicion[player] = nil

	local counters = self._counts[player]
	if not counters then
		return
	end
	self._counts[player] = nil

	local server = self._counts[SERVER]
	if not server then
		server = { Keys = 0, Counters = {} }
		self._counts[SERVER] = server
	end

	for key, counter in counters.Counters do
		if counter.Count > 0 then
			self:_log(player, counter)
		end
		local merged = server.Counters[key]
		if merged then
			merged.Count += counter.Count
		else
			server.Counters[key] = table.clone(counter)
			server.Keys += 1
		end
	end
end

-- Flushes what was counted so far, then stops the flush timer.
function Telemetry.Destroy(self: Telemetry): ()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local cancel = self._cancel_flush
	self._cancel_flush = nil
	if cancel then
		cancel()
	end

	local ok, err = pcall(function()
		self:Flush()
	end)
	if not ok then
		warn(("[Telemetry] final flush failed: %s"):format(tostring(err)))
	end
end

return Telemetry
