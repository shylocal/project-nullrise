--!strict
-- Observes every live character's replicated root position and reports
-- displacement outside the movement envelope (derived from movement and
-- parkour tuning by shared/config/Envelope). It only reports: violations are
-- counted in Telemetry and logged at a limited rate, nothing is corrected.
-- Positions come from PositionHistory: each history step writes a sample per
-- live character and then fires Stepped, which drives one observation here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)

local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)
local PositionHistory = require(script.Parent.PositionHistory)
local Telemetry = require(script.Parent.Telemetry)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession
type Reason = RejectReason.Reason

-- Speed limits in studs per second (Envelope.Limits satisfies this).
export type Limits = {
	MaxHorizontalSpeed: number,
	MaxUpwardSpeed: number,
	MaxDownwardSpeed: number,
	TeleportDistance: number,
}

export type MovementValidationDeps = {
	players: PlayerService,
	telemetry: Telemetry.Telemetry,
	scheduler: Scheduler.Scheduler,
	history: PositionHistory.PositionHistory,
	limits: Limits,
}

export type Report = {
	ViolationCount: number,
	LastReason: Reason?,
	LastViolationAt: number,
}

-- FallStartY is the fall apex at the sample's time.
type Sample = { Position: Vector3, Time: number, FallStartY: number }

type State = {
	Character: Model?,
	-- Ordered samples covering at most SAMPLE_WINDOW.
	Samples: { Sample },
	-- Highest point of the current descent; nil while nothing is tracked.
	FallStartY: number?,
	LastDescentAt: number,
	IgnoreUntil: number,
	ViolationCount: number,
	LastReason: Reason?,
	LastViolationAt: number,
}

local MovementValidation = {}
MovementValidation.__index = MovementValidation

local MAX_SAMPLE_GAP = 0.5
-- Movement is judged over a short window so a burst of delayed position
-- updates is averaged against the time it actually covers.
local SAMPLE_WINDOW = 1
local MIN_WINDOW_SPAN = 0.25
local DESCENT_EPSILON = 0.05
local FALL_RESET_DELAY = 0.5
local LOG_INTERVAL = 1
local CHARACTER_GRACE_PERIOD = 1.5
local ROOT_PART = Config.World.Names.RootPart

-- Observation window tuning. Speed limits are per instance (self.Limits).
MovementValidation.Window = table.freeze({
	MaxSampleGap = MAX_SAMPLE_GAP,
	SampleWindow = SAMPLE_WINDOW,
	MinWindowSpan = MIN_WINDOW_SPAN,
	FallResetDelay = FALL_RESET_DELAY,
	CharacterGracePeriod = CHARACTER_GRACE_PERIOD,
})

local function finite_vector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return math.isfinite(vector.X) and math.isfinite(vector.Y) and math.isfinite(vector.Z)
end

-- Roblox has no terminal velocity, so the downward bound follows free fall:
-- v = sqrt(v0^2 + 2 * g * h), where h is the height fallen since the last apex.
function MovementValidation.GetMaxFallSpeed(fall_height: number, limits: Limits): number
	local gravity = math.max(Workspace.Gravity, 0)
	local base = limits.MaxDownwardSpeed
	return math.sqrt(base * base + 2 * gravity * math.max(fall_height, 0))
end

-- The reason a displacement is outside the envelope, or nil when it is
-- inside it or the sample is unusable (non-finite, or a bad time span).
function MovementValidation.ClassifyDelta(
	previous_position: Vector3,
	current_position: Vector3,
	delta_time: number,
	fall_height: number?,
	limits: Limits
): Reason?
	if not finite_vector(previous_position)
		or not finite_vector(current_position)
		or type(delta_time) ~= "number"
		or not math.isfinite(delta_time)
		or delta_time <= 0
		or delta_time > SAMPLE_WINDOW then
		return nil
	end

	local fallen = if fall_height == nil then 0 else fall_height
	if type(fallen) ~= "number" or not math.isfinite(fallen) then
		return nil
	end

	local delta = current_position - previous_position
	local horizontal_distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local allowed_horizontal = limits.MaxHorizontalSpeed * delta_time
	local allowed_vertical = if delta.Y > 0
		then limits.MaxUpwardSpeed * delta_time
		else MovementValidation.GetMaxFallSpeed(fallen, limits) * delta_time

	local horizontal_excess = math.max(horizontal_distance - allowed_horizontal, 0)
	local vertical_excess = math.max(math.abs(delta.Y) - allowed_vertical, 0)
	if Vector3.new(horizontal_excess, vertical_excess, 0).Magnitude > limits.TeleportDistance then
		return RejectReason.TeleportDistance
	end

	if horizontal_excess > 0 then
		return RejectReason.HorizontalSpeed
	end

	if vertical_excess > 0 then
		return RejectReason.VerticalSpeed
	end

	return nil
end

local function get_live_root(character: Model?): BasePart?
	if not character or character.Parent == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild(ROOT_PART)
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end

	return root
end

-- Limits come from config math; they are checked once at construction.
local function check_limits(limits: Limits)
	if type(limits) ~= "table" then
		error("MovementValidation.new: limits must be a table", 3)
	end
	local values: { [string]: unknown } = limits :: any
	for _, key in { "MaxHorizontalSpeed", "MaxUpwardSpeed", "MaxDownwardSpeed", "TeleportDistance" } do
		local value = values[key]
		if type(value) ~= "number" or not (value > 0) or value == math.huge then
			error(("MovementValidation.new: limits.%s must be a positive finite number"):format(key), 3)
		end
	end
end

type MovementValidationFields = {
	Trove: PlayerSession.Trove,
	Limits: Limits,

	_players: PlayerService,
	_telemetry: Telemetry.Telemetry,
	_scheduler: Scheduler.Scheduler,
	_history: PositionHistory.PositionHistory,
}

export type MovementValidation = typeof(setmetatable({} :: MovementValidationFields, MovementValidation))

function MovementValidation.new(deps: MovementValidationDeps): MovementValidation
	Deps.check(deps, "MovementValidation", { "players", "telemetry", "scheduler", "history", "limits" })
	check_limits(deps.limits)

	local fields: MovementValidationFields = {
		Trove = Trove.new(),
		Limits = deps.limits,

		_players = deps.players,
		_telemetry = deps.telemetry,
		_scheduler = deps.scheduler,
		_history = deps.history,
	}
	local self = setmetatable(fields, MovementValidation)

	self.Trove:Connect(deps.history.Stepped, function(now: number)
		self:_step(now)
	end)

	deps.players:Register(self, "MovementValidation")

	return self
end

local function new_state(): State
	return {
		Character = nil,
		Samples = {},
		FallStartY = nil,
		LastDescentAt = 0,
		IgnoreUntil = 0,
		ViolationCount = 0,
		LastReason = nil,
		LastViolationAt = -math.huge,
	}
end

function MovementValidation.OnPlayerAdded(self: MovementValidation, session: PlayerSession)
	session:Set(self, new_state())
end

function MovementValidation.OnCharacterAdded(self: MovementValidation, session: PlayerSession, character: Model)
	local state = session:Get(self) :: State?
	if state then
		self:_reset_character(state, character)
	end
end

function MovementValidation.OnCharacterRemoving(self: MovementValidation, session: PlayerSession, character: Model)
	local state = session:Get(self) :: State?
	if state and state.Character == character then
		self:_reset_character(state, nil)
	end
end

function MovementValidation.OnPlayerRemoving(self: MovementValidation, session: PlayerSession)
	session:Clear(self)
end

-- Each sample remembers the fall apex at its time, so a replication stall
-- mid-fall that resets FallStartY cannot shrink the bound for samples taken
-- before the stall. Samples are only added while FallStartY is tracked.
local function add_sample(state: State, position: Vector3, now: number)
	table.insert(state.Samples, {
		Position = position,
		Time = now,
		FallStartY = state.FallStartY :: number,
	})
end

local function restart_window(state: State, position: Vector3, now: number)
	table.clear(state.Samples)
	add_sample(state, position, now)
end

local function reset_tracking(state: State, position: Vector3?, now: number)
	table.clear(state.Samples)
	state.FallStartY = nil

	if position then
		state.FallStartY = position.Y
		state.LastDescentAt = now
		restart_window(state, position, now)
	end
end

-- FallStartY tracks the highest point of the current descent. It follows the
-- character up, and resets once the character has stopped descending for a
-- while, so a short stall in replicated positions mid-fall keeps the fall.
local function update_fall(state: State, previous_y: number, y: number, now: number)
	if y < previous_y - DESCENT_EPSILON then
		state.LastDescentAt = now
	end

	if y >= (state.FallStartY :: number) or now - state.LastDescentAt >= FALL_RESET_DELAY then
		state.FallStartY = y
	end
end

function MovementValidation._reset_character(self: MovementValidation, state: State, character: Model?)
	local now = self._scheduler.clock()
	state.Character = character
	state.ViolationCount = 0
	state.LastReason = nil
	state.LastViolationAt = -math.huge
	state.IgnoreUntil = now + CHARACTER_GRACE_PERIOD

	local root = get_live_root(character)
	reset_tracking(state, root and root.Position, now)
end

function MovementValidation._observe(self: MovementValidation, player: Player, state: State, now: number)
	-- PositionHistory writes a sample this step only for a live character.
	local character = state.Character
	local sample = character and self._history:Latest(character)
	if not sample or sample.Time ~= now or not finite_vector(sample.RootCFrame.Position) then
		reset_tracking(state, nil, now)
		return
	end
	local position = sample.RootCFrame.Position

	local samples = state.Samples
	local last = samples[#samples]
	if not last then
		reset_tracking(state, position, now)
		return
	end

	-- Keep following the fall through spawn settling and server hitches so a
	-- character already falling fast is not judged against a fresh apex.
	update_fall(state, last.Position.Y, position.Y, now)

	-- Spawn settling and server hitches both make the window untrustworthy.
	if now < state.IgnoreUntil or now - last.Time > MAX_SAMPLE_GAP then
		restart_window(state, position, now)
		return
	end

	add_sample(state, position, now)

	while now - samples[1].Time > SAMPLE_WINDOW do
		table.remove(samples, 1)
	end

	local oldest = samples[1]
	local span = now - oldest.Time
	if span < MIN_WINDOW_SPAN then
		return
	end

	local fall_start_y = math.max(state.FallStartY :: number, oldest.FallStartY)
	local reason = MovementValidation.ClassifyDelta(
		oldest.Position,
		position,
		span,
		fall_start_y - position.Y,
		self.Limits
	)

	if not reason then
		return
	end

	-- Start a fresh window so one violation is not re-reported every frame
	-- until it slides out of the window.
	restart_window(state, position, now)

	state.ViolationCount += 1
	state.LastReason = reason
	self._telemetry:Count(player, "Movement", reason)

	if now - state.LastViolationAt >= LOG_INTERVAL then
		state.LastViolationAt = now
		warn(
			("[MovementValidation] %s (%d) reported %s: position delta exceeded the prototype movement envelope")
				:format(player.Name, player.UserId, reason)
		)
	end
end

function MovementValidation._step(self: MovementValidation, now: number)
	-- Iterates the live session map directly: this runs every frame.
	for _, session in self._players.Sessions do
		local state = session:Get(self) :: State?
		if state and session.Phase == "Ready" then
			self:_observe(session.Player, state, now)
		end
	end
end

function MovementValidation.GetReport(self: MovementValidation, player: Player): Report?
	local session = self._players:Get(player)
	local state = session and session:Get(self) :: State?
	if not state then
		return nil
	end

	return {
		ViolationCount = state.ViolationCount,
		LastReason = state.LastReason,
		LastViolationAt = state.LastViolationAt,
	}
end

function MovementValidation.Destroy(self: MovementValidation)
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return MovementValidation
