local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local MovementValidation = {}
MovementValidation.__index = MovementValidation

local MAX_HORIZONTAL_SPEED = 96
local MAX_VERTICAL_SPEED = 240
local MAX_SAMPLE_GAP = 0.5
local TELEPORT_DISTANCE = 40
local LOG_INTERVAL = 1
local CHARACTER_GRACE_PERIOD = 1.5

MovementValidation.Limits = {
	MaxHorizontalSpeed = MAX_HORIZONTAL_SPEED,
	MaxVerticalSpeed = MAX_VERTICAL_SPEED,
	MaxSampleGap = MAX_SAMPLE_GAP,
	TeleportDistance = TELEPORT_DISTANCE,
	CharacterGracePeriod = CHARACTER_GRACE_PERIOD,
}

local function finite_vector(value)
	return typeof(value) == "Vector3"
		and math.isfinite(value.X)
		and math.isfinite(value.Y)
		and math.isfinite(value.Z)
end

function MovementValidation.ClassifyDelta(previous_position, current_position, delta_time)
	if not finite_vector(previous_position)
		or not finite_vector(current_position)
		or typeof(delta_time) ~= "number"
		or not math.isfinite(delta_time)
		or delta_time <= 0
		or delta_time > MAX_SAMPLE_GAP then
		return nil
	end

	local delta = current_position - previous_position
	local distance = delta.Magnitude
	if distance > TELEPORT_DISTANCE then
		return "TeleportDistance"
	end

	local horizontal_distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
	if horizontal_distance / delta_time > MAX_HORIZONTAL_SPEED then
		return "HorizontalSpeed"
	end

	if math.abs(delta.Y) / delta_time > MAX_VERTICAL_SPEED then
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

function MovementValidation:_watch_player(player)
	if self.Players[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	local state = {
		Character = nil,
		Position = nil,
		LastSampleAt = nil,
		ViolationCount = 0,
		LastReason = nil,
		LastViolationAt = 0,
		Trove = Trove.new(),
	}
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

function MovementValidation:_reset_character(player, character)
	local state = self.Players[player]
	if not state then
		return
	end

	state.Character = character
	state.Position = nil
	state.LastSampleAt = nil
	state.ViolationCount = 0
	state.LastReason = nil
	state.LastViolationAt = 0
	state.IgnoreUntil = os.clock() + CHARACTER_GRACE_PERIOD

	local root = get_live_root(character)
	if root then
		state.Position = root.Position
		state.LastSampleAt = os.clock()
	end
end

function MovementValidation:_observe(player, state, now)
	local character = state.Character
	local root = get_live_root(character)
	if not root then
		state.Position = nil
		state.LastSampleAt = nil
		return
	end

	local position = root.Position
	local sample_at = state.LastSampleAt
	if not state.Position or not sample_at then
		state.Position = position
		state.LastSampleAt = now
		return
	end

	local delta_time = now - sample_at
	if now < (state.IgnoreUntil or 0) then
		state.LastSampleAt = now
		state.Position = position
		return
	end

	local reason = MovementValidation.ClassifyDelta(state.Position, position, delta_time)

	state.Position = position
	state.LastSampleAt = now

	if not reason then
		return
	end

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
