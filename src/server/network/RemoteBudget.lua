--!strict
-- Token buckets for inbound remote traffic: one per player per action, plus
-- one global bucket per player. Bucket state is session state, so it lives
-- as long as the player is in the server and does not reset on respawn.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local services = script.Parent.Parent.services
local PlayerService = require(services.PlayerService)
local PlayerSession = require(services.PlayerSession)
local Telemetry = require(services.Telemetry)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession

export type Rate = { Rate: number, Burst: number }
export type BudgetConfig = { Global: Rate, Actions: { [string]: Rate } }

type Bucket = {
	Tokens: number,
	At: number,
}

type BudgetState = {
	Global: Bucket,
	Actions: { [string]: Bucket },
}

export type RemoteBudgetDeps = {
	players: PlayerService,
	config: BudgetConfig,
	clock: () -> number,
	telemetry: Telemetry.Telemetry,
	-- Studio prints the raw name of each unknown action.
	is_studio: boolean,
	-- PlayerService component name. Only specs that run a second budget next
	-- to the composed one need to set it.
	component_name: string?,
}

type RemoteBudgetFields = {
	_players: PlayerService,
	_config: BudgetConfig,
	_clock: () -> number,
	_telemetry: Telemetry.Telemetry,
	_is_studio: boolean,
}

-- Telemetry detail for an unknown action. The action name after the remote
-- prefix comes from the client, and telemetry details reach AnalyticsService
-- custom fields, so only the server-chosen remote name is kept.
local UNKNOWN = "<unknown>"
local function unknown_detail(action: string): string
	local remote = string.match(action, "^([^.]+)%.")
	return if remote then remote .. "." .. UNKNOWN else UNKNOWN
end

local RemoteBudget = {}
RemoteBudget.__index = RemoteBudget
RemoteBudget.UNKNOWN = UNKNOWN

export type RemoteBudget = typeof(setmetatable({} :: RemoteBudgetFields, RemoteBudget))

-- Config is checked at runtime as well, so `rate` is read untyped.
local function check_rate(rate: any, path: string)
	if type(rate) ~= "table" then
		error(("RemoteBudget.new: %s must be a table"):format(path), 3)
	end
	for _, key in { "Rate", "Burst" } do
		local value = rate[key]
		if type(value) ~= "number" or not (value >= 1) or value == math.huge then
			error(("RemoteBudget.new: %s.%s must be a finite number >= 1"):format(path, key), 3)
		end
	end
end

function RemoteBudget.new(deps: RemoteBudgetDeps): RemoteBudget
	Deps.check(deps, "RemoteBudget", { "players", "config", "clock", "telemetry", "is_studio" })

	check_rate(deps.config.Global, "Global")
	if type(deps.config.Actions) ~= "table" then
		error("RemoteBudget.new: Actions must be a table", 2)
	end
	for action, rate in deps.config.Actions do
		check_rate(rate, ("Actions[%q]"):format(action))
	end

	local fields: RemoteBudgetFields = {
		_players = deps.players,
		_config = deps.config,
		_clock = deps.clock,
		_telemetry = deps.telemetry,
		_is_studio = deps.is_studio,
	}
	local self = setmetatable(fields, RemoteBudget)

	deps.players:Register(self, deps.component_name or "RemoteBudget")

	return self
end

local function new_state(self: RemoteBudget): BudgetState
	return {
		Global = { Tokens = self._config.Global.Burst, At = self._clock() },
		Actions = {},
	}
end

local function refill(bucket: Bucket, rate: Rate, now: number)
	local elapsed = math.max(now - bucket.At, 0)
	bucket.Tokens = math.min(rate.Burst, bucket.Tokens + rate.Rate * elapsed)
	bucket.At = now
end

function RemoteBudget.OnPlayerAdded(self: RemoteBudget, session: PlayerSession): ()
	session:Set(self, new_state(self))
end

function RemoteBudget.OnPlayerRemoving(self: RemoteBudget, session: PlayerSession): ()
	session:Clear(self)
end

-- True when both the action bucket and the global bucket hold a token; one
-- token is then taken from each. Counts any session, in any phase.
function RemoteBudget.Take(self: RemoteBudget, player: Player, action: string): boolean
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return false
	end

	local state = session:Get(self) :: BudgetState?
	if not state then
		-- A request can arrive before this component's OnPlayerAdded ran.
		local created = new_state(self)
		session:Set(self, created)
		state = created
	end
	assert(state, "unreachable")

	local now = self._clock()
	local global_rate = self._config.Global
	local global = state.Global
	refill(global, global_rate, now)

	local rate = self._config.Actions[action]
	if not rate then
		-- Unknown actions still cost global budget, so they cannot be used
		-- to probe the server for free.
		if global.Tokens >= 1 then
			global.Tokens -= 1
		end
		self._telemetry:Count(player, "Network", "UnknownAction", unknown_detail(action))
		if self._is_studio then
			print(("[RemoteBudget] unknown action %q from %s"):format(string.sub(action, 1, 64), tostring(player.Name)))
		end
		return false
	end

	local bucket = state.Actions[action]
	if not bucket then
		bucket = { Tokens = rate.Burst, At = now }
		state.Actions[action] = bucket
	end
	assert(bucket, "unreachable")
	refill(bucket, rate, now)

	if bucket.Tokens < 1 or global.Tokens < 1 then
		self._telemetry:Count(player, "Network", "RateLimited", action)
		return false
	end

	bucket.Tokens -= 1
	global.Tokens -= 1
	return true
end

function RemoteBudget.Destroy(self: RemoteBudget): ()
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end
end

return RemoteBudget
