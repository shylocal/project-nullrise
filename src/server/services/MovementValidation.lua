local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local MovementValidation = {}
MovementValidation.__index = MovementValidation

local MAX_HORIZONTAL_SPEED = 96
local MAX_UPWARD_SPEED = 240
-- Downward speed allowed before any fall height is accumulated. Gravity adds
-- to this per fall, see GetMaxFallSpeed.
local MAX_DOWNWARD_SPEED = 240
local MAX_SAMPLE_GAP = 0.5
-- Movement is judged over a short window so a burst of delayed position
-- updates is averaged against the time it actually covers.
local SAMPLE_WINDOW = 1
local MIN_WINDOW_SPAN = 0.25
local TELEPORT_DISTANCE = 40
local DESCENT_EPSILON = 0.05
local FALL_RESET_DELAY = 0.5
local LOG_INTERVAL = 1
local CHARACTER_GRACE_PERIOD = 1.5

MovementValidation.Limits = {
	MaxHorizontalSpeed = MAX_HORIZONTAL_SPEED,
	MaxUpwardSpeed = MAX_UPWARD_SPEED,
	MaxDownwardSpeed = MAX_DOWNWARD_SPEED,
	MaxSampleGap = MAX_SAMPLE_GAP,
	SampleWindow = SAMPLE_WINDOW,
	MinWindowSpan = MIN_WINDOW_SPAN,
	TeleportDistance = TELEPORT_DISTANCE,
	FallResetDelay = FALL_RESET_DELAY,
	CharacterGracePeriod = CHARACTER_GRACE_PERIOD,
}

local function finite_vector(value)
	return typeof(value) == "Vector3"
		and math.isfinite(value.X)
		and math.isfinite(value.Y)
		and math.isfinite(value.Z)
end

-- Roblox has no terminal velocity, so the downward bound follows free fall:
-- v = sqrt(v0^2 + 2 * g * h), where h is the height fallen since the last apex.
function MovementValidation.GetMaxFallSpeed(fall_height)
	local gravity = math.max(Workspace.Gravity, 0)
	return math.sqrt(MAX_DOWNWARD_SPEED * MAX_DOWNWARD_SPEED + 2 * gravity * math.max(fall_height, 0))
end

function MovementValidation.ClassifyDelta(previous_position, current_position, delta_time, fall_height)
	if not finite_vector(previous_position)
		or not finite_vector(current_position)
		or typeof(delta_time) ~= "number"
		or not math.isfinite(delta_time)
		or delta_time <= 0
		or delta_time > SAMPLE_WINDOW then
		return nil
	end

	if fall_height == nil then
		fall_height = 0
	elseif typeof(fall_height) ~= "number" or not math.isfinite(fall_height) then
		return nil
	end

	local delta = current_position - previous_position
	local horizontal_distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local allowed_horizontal = MAX_HORIZONTAL_SPEED * delta_time
	local allowed_vertical = if delta.Y > 0
		then MAX_UPWARD_SPEED * delta_time
		else MovementValidation.GetMaxFallSpeed(fall_height) * delta_time

	local horizontal_excess = math.max(horizontal_distance - allowed_horizontal, 0)
	local vertical_excess = math.max(math.abs(delta.Y) - allowed_vertical, 0)
	if Vector3.new(horizontal_excess, vertical_excess, 0).Magnitude > TELEPORT_DISTANCE then
		return "TeleportDistance"
	end

	if horizontal_excess > 0 then
		return "HorizontalSpeed"
	end

	if vertical_excess > 0 then
		return "VerticalSpeed"
	end

	return nil
end

MovementValidation.CharacterGracePeriod = CHARACTER_GRACE_PERIOD

local function get_live_root(character)
	if not character or character.Parent == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end

	return root
end

function MovementValidation.new(player_service)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		Players = {},
	}, MovementValidation)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function MovementValidation:_start()
	self.Trove:Connect(
		self.PlayerService.PlayerAdded,
		function(player)
			self:_watch_player(player)
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerRemoving,
		function(player)
			self:_player_removing(player)
		end
	)

	self.Trove:Connect(
		RunService.Heartbeat,
		function()
			self:_step()
		end
	)

	for _, player in self.PlayerService:GetPlayers() do
		self:_watch_player(player)
	end
end

function MovementValidation._create_state()
	return {
		Character = nil,
		-- Ordered { Position, Time } samples covering at most SAMPLE_WINDOW.
		Samples = {},
		FallStartY = nil,
		LastDescentAt = 0,
		IgnoreUntil = 0,
		ViolationCount = 0,
		LastReason = nil,
		LastViolationAt = 0,
	}
end

function MovementValidation:_watch_player(player)
	if self.Players[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	local state = MovementValidation._create_state()
	state.Trove = Trove.new()
	self.Players[player] = state

	state.Trove:Connect(
		session.CharacterAdded,
		function(character)
			self:_reset_character(player, character)
		end
	)

	state.Trove:Connect(
		session.CharacterRemoving,
		function(character)
			if state.Character == character then
				self:_reset_character(player, nil)
			end
		end
	)

	if session.Character then
		self:_reset_character(player, session.Character)
	end
end

-- Each sample remembers the fall apex at its time, so a replication stall
-- mid-fall that resets FallStartY cannot shrink the bound for samples taken
-- before the stall.
local function add_sample(state, position, now)
	table.insert(state.Samples, {
		Position = position,
		Time = now,
		FallStartY = state.FallStartY,
	})
end

local function restart_window(state, position, now)
	table.clear(state.Samples)
	add_sample(state, position, now)
end

local function reset_tracking(state, position, now)
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
local function update_fall(state, previous_y, y, now)
	if y < previous_y - DESCENT_EPSILON then
		state.LastDescentAt = now
	end

	if y >= state.FallStartY or now - state.LastDescentAt >= FALL_RESET_DELAY then
		state.FallStartY = y
	end
end

function MovementValidation:_reset_character(player, character)
	local state = self.Players[player]
	if not state then
		return
	end

	local now = os.clock()
	state.Character = character
	state.ViolationCount = 0
	state.LastReason = nil
	state.LastViolationAt = 0
	state.IgnoreUntil = now + CHARACTER_GRACE_PERIOD

	local root = get_live_root(character)
	reset_tracking(state, root and root.Position, now)
end

function MovementValidation:_observe(player, state, now)
	local root = get_live_root(state.Character)
	local position = root and root.Position
	if not finite_vector(position) then
		reset_tracking(state, nil, now)
		return
	end

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

	local fall_start_y = math.max(state.FallStartY, oldest.FallStartY)
	local reason = MovementValidation.ClassifyDelta(
		oldest.Position,
		position,
		span,
		fall_start_y - position.Y
	)

	if not reason then
		return
	end

	-- Start a fresh window so one violation is not re-reported every frame
	-- until it slides out of the window.
	restart_window(state, position, now)

	state.ViolationCount += 1
	state.LastReason = reason

	if now - state.LastViolationAt >= LOG_INTERVAL then
		state.LastViolationAt = now
		warn(
			("[MovementValidation] %s (%d) reported %s: position delta exceeded the prototype movement envelope")
				:format(player.Name, player.UserId, reason)
		)
	end
end

function MovementValidation:_step()
	local now = os.clock()
	for player, state in pairs(self.Players) do
		self:_observe(player, state, now)
	end
end

function MovementValidation:GetReport(player)
	local state = self.Players[player]
	if not state then
		return nil
	end

	return {
		ViolationCount = state.ViolationCount,
		LastReason = state.LastReason,
		LastViolationAt = state.LastViolationAt,
	}
end

function MovementValidation:_player_removing(player)
	local state = self.Players[player]
	if not state then
		return
	end

	state.Trove:Destroy()
	self.Players[player] = nil
end

function MovementValidation:Destroy()
	for player in pairs(self.Players) do
		self:_player_removing(player)
	end

	table.clear(self.Players)
	self.Trove:Destroy()
end

return MovementValidation
