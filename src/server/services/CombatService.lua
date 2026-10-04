-- Authoritative melee combat. Each player's combo cursor and active move are
-- PlayerService component state. Every inbound Combat action is charged
-- against the RemoteBudget first; every dropped request is counted in
-- Telemetry with a RejectReason. Hits that pass validation go to
-- DamageService, the only place damage is dealt.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local CombatValidation = require(script.Parent.CombatValidation)
local MoveKinds = require(script.Parent.MoveKinds)

local CombatActions = Protocol.Combat
local CombatConfig = Config.Combat
local LagCompensation = CombatConfig.LagCompensation

-- Move timing (HitStartAt, HitWindow, MinDuration, Hold.MaxHoldTime) comes
-- from the validated weapon definitions. The tolerance only absorbs jitter
-- between two packets sent by the same client.
local TIMING_TOLERANCE = CombatConfig.TimingTolerance
local MAX_HITS_PER_ATTACK = CombatConfig.MaxHitsPerAttack
-- Bounds the spatial validation work (raycasts) a single move can cause,
-- independently of how many of those hits are accepted.
local MAX_HIT_REQUESTS_PER_ATTACK = CombatConfig.MaxHitRequestsPerAttack
local MAX_REJECTS_PER_TARGET = CombatConfig.MaxRejectsPerTarget
local REJECT_REPLY_INTERVAL = CombatConfig.RejectReplyInterval

-- Telemetry reasons for outcomes that are not request rejects.
local REWOUND = "Rewound"

local function is_move_id(value)
	return typeof(value) == "number" and math.isfinite(value) and value % 1 == 0
end

-- The move with this id on `weapon` (a catalog definition, or a copy of one).
local function move_of(weapon, move_id)
	for _, move in pairs(weapon.Moves) do
		if move.Id == move_id then
			return move
		end
	end
	return nil
end

-- True for a move named directly by the weapon's bindings (the Hold move, or
-- a Tap move when Tap is not the combo).
local function is_bound(weapon, move)
	local primary = weapon.Bindings.Primary
	return primary.Hold == move.Name or (primary.Tap ~= Validator.ComboTap and primary.Tap == move.Name)
end

local CombatService = {}
CombatService.__index = CombatService

function CombatService.new(deps)
	Deps.check(deps, "CombatService", {
		"players",
		"weapons",
		"remote",
		"budget",
		"telemetry",
		"scheduler",
		"damage",
		"history",
	})

	local self = setmetatable({
		Trove = Trove.new(),

		_players = deps.players,
		_weapons = deps.weapons,
		_remote = deps.remote,
		_budget = deps.budget,
		_telemetry = deps.telemetry,
		_scheduler = deps.scheduler,
		_damage = deps.damage,
		_history = deps.history,
	}, CombatService)

	self.Trove:Connect(
		self._remote.OnServerEvent,
		function(player, action, move_id, hit_character, segment_instance, hit_position)
			self:_on_remote(player, action, move_id, hit_character, segment_instance, hit_position)
		end
	)

	self.Trove:Connect(self._weapons.EquippedChanged, function(player)
		local state = self:_state(player)
		if state then
			self:_reset_attack_sequence(state)
		end
	end)

	deps.players:Register(self, "CombatService")

	return self
end

local function clear_attack(state)
	local active = state.Active
	if not active then
		return
	end

	state.Active = nil
	table.clear(active.HitTargets)
	table.clear(active.Rejected)

	local cancel_expiry = active.CancelExpiry
	active.CancelExpiry = nil
	if cancel_expiry then
		cancel_expiry()
	end

	local cancel_pending = active.CancelPendingHitStart
	active.CancelPendingHitStart = nil
	active.PendingHitStart = false
	if cancel_pending then
		cancel_pending()
	end
end

local function new_state()
	return {
		Active = nil,
		-- 1-based cursor into the equipped weapon's Combo.
		ComboIndex = 1,
		NextAttackAt = nil,
		LastThrottledRejectAt = -math.huge,
		Destroy = clear_attack,
	}
end

function CombatService:OnPlayerAdded(session)
	session:Set(self, new_state())
end

function CombatService:OnCharacterRemoving(session)
	local state = session:Get(self)
	if not state then
		return
	end

	self:_reset_attack_sequence(state)
	state.NextAttackAt = nil
end

function CombatService:OnPlayerRemoving(session)
	session:Clear(self)
end

-- State of a Ready session; remote traffic is never acted on otherwise.
function CombatService:_state(player)
	local session = self._players:GetReady(player)
	return session and session:Get(self), session
end

function CombatService:_count(player, reason, weapon_id)
	self._telemetry:Count(player, "Combat", reason, weapon_id)
end

function CombatService:_equipped_id(player)
	local weapon = self._weapons:GetEquipped(player)
	return weapon and weapon.Id
end

-- The combo move the server expects next, or nil without an equipped weapon.
function CombatService:_next_combo_move_id(player, state)
	local weapon = self._weapons:GetEquipped(player)
	if not state or not Catalog.IsEquippable(weapon) then
		return nil
	end
	if state.ComboIndex > #weapon.Combo then
		state.ComboIndex = 1
	end
	return Catalog.ComboMoveId(weapon, state.ComboIndex)
end

function CombatService:_on_remote(player, action, move_id, hit_character, segment_instance, hit_position)
	if typeof(action) ~= "string" then
		self._telemetry:Count(player, "Network", RejectReason.BadPayload, "Combat")
		return
	end

	local allowed = self._budget:Take(player, "Combat." .. action)

	if action == CombatActions.Attack then
		self:_request_attack(player, move_id, allowed)
		return
	end

	if not allowed then
		return
	end

	if action ~= CombatActions.HitStart and action ~= CombatActions.HitStop and action ~= CombatActions.Hit then
		return
	end

	if not is_move_id(move_id) then
		self:_count(player, RejectReason.BadPayload, self:_equipped_id(player))
		return
	end

	if action == CombatActions.HitStart then
		self:_hit_start(player, move_id)
	elseif action == CombatActions.HitStop then
		self:_hit_stop(player, move_id)
	else
		self:_hit(player, move_id, hit_character, segment_instance, hit_position)
	end
end

function CombatService:_get_attack_context(player, session)
	local character = session.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not CharacterQuery.is_alive(humanoid) then
		return nil
	end

	local weapon = self._weapons:GetEquipped(player)
	if not Catalog.IsEquippable(weapon) then
		return nil
	end

	return character, weapon
end

function CombatService:_can_begin_attack(state)
	local now = self._scheduler.clock()
	local next_attack_at = state.NextAttackAt

	-- Allow a small amount of network jitter so the client's local cooldown
	-- and the server's monotonic clock do not disagree on boundary frames.
	if next_attack_at and now + TIMING_TOLERANCE < next_attack_at then
		return nil
	end

	return now
end

function CombatService:_create_active(state, weapon, move, wielded, character, started_at)
	local kind = MoveKinds[move.Kind]
	local timing = kind.create_timing(move, started_at, TIMING_TOLERANCE)

	local active = {
		MoveId = move.Id,
		Move = move,
		Kind = kind,
		WeaponId = weapon.Id,
		Character = character,
		Wielded = wielded,
		HitActive = false,
		HitExpiresAt = nil,
		-- An early HitStart is armed and activates at HitStartOpensAt.
		PendingHitStart = false,
		CancelPendingHitStart = nil,
		HitTargets = {},
		Rejected = {},
		HitCount = 0,
		HitRequests = 0,
		ValidationRaycastParams = RaycastParams.new(),
		StartedAt = started_at,
		HitStartOpensAt = timing.HitStartOpensAt,
		HitStartClosesAt = timing.HitStartClosesAt,
		ExpiresAt = timing.ExpiresAt,
		CancelExpiry = nil,
	}

	clear_attack(state)
	state.Active = active

	active.CancelExpiry = self._scheduler.after(timing.ExpiresAt - started_at, function()
		if state.Active == active then
			clear_attack(state)
		end
	end)

	return active
end

function CombatService:_reply_rejected(player, requested_move_id, state)
	self._remote:FireClient(
		player,
		CombatActions.AttackRejected,
		requested_move_id,
		self:_next_combo_move_id(player, state)
	)
end

-- Malformed and budget-dropped Attack requests are answered at most once per
-- RejectReplyInterval, so a flood of bad requests cannot be amplified into a
-- flood of replies. The client's pending-attack timeout covers the rest.
function CombatService:_reply_throttled(player, requested_move_id, state)
	if not state then
		return
	end

	local now = self._scheduler.clock()
	if now - state.LastThrottledRejectAt < REJECT_REPLY_INTERVAL then
		return
	end

	state.LastThrottledRejectAt = now
	self:_reply_rejected(player, requested_move_id, state)
end

-- Every well-formed Attack request that passes the budget is answered with
-- exactly one AttackAccepted or AttackRejected, for combo and bound moves alike.
function CombatService:_request_attack(player, move_id, allowed)
	local state, session = self:_state(player)

	if not is_move_id(move_id) then
		self:_count(player, RejectReason.BadPayload, self:_equipped_id(player))
		self:_reply_throttled(player, nil, state)
		return
	end

	if not allowed then
		self:_reply_throttled(player, move_id, state)
		return
	end

	if not state or not self:_attack(player, session, state, move_id) then
		self:_reply_rejected(player, move_id, state)
	end
end

-- Returns true after sending AttackAccepted; the caller rejects otherwise.
-- The combo-expected move advances the combo cursor; a move bound directly in
-- Bindings (the Heavy hold) is accepted without touching it.
function CombatService:_attack(player, session, state, move_id)
	local character, weapon = self:_get_attack_context(player, session)
	if not character then
		self:_count(player, RejectReason.AttackerInvalid, self:_equipped_id(player))
		return false
	end

	local move = move_of(weapon, move_id)
	if not move then
		self:_count(player, RejectReason.BadPayload, weapon.Id)
		return false
	end

	-- The previous move's MinDuration (stored in NextAttackAt) is enforced
	-- here, so starting a new move cannot be used to skip ahead of it.
	local now = self:_can_begin_attack(state)
	if not now then
		return false
	end

	local is_combo = move_id == self:_next_combo_move_id(player, state)
	if not is_combo and not is_bound(weapon, move) then
		return false
	end

	local wielded = self._weapons:GetWielded(player, move.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		self:_count(player, RejectReason.WieldMismatch, weapon.Id)
		return false
	end

	if is_combo then
		state.ComboIndex = state.ComboIndex % #weapon.Combo + 1
	end
	state.NextAttackAt = math.max(state.NextAttackAt or 0, now + move.MinDuration)

	self:_create_active(state, weapon, move, wielded, character, now)
	self._remote:FireClient(
		player,
		CombatActions.AttackAccepted,
		move_id,
		self:_next_combo_move_id(player, state)
	)
	return true
end

local function is_active_attacker_valid(session, active)
	if not session or session.Character ~= active.Character then
		return false
	end

	local character = active.Character
	if not character or character.Parent == nil then
		return false
	end

	return CharacterQuery.is_alive(character:FindFirstChildOfClass("Humanoid"))
end

local function activate_hit(active, now)
	active.HitActive = true
	-- A light move's hits close with the move; a charge's hit window starts
	-- at its release (this HitStart).
	active.HitExpiresAt = active.Kind.hit_expires_at(active.Move, active, now, TIMING_TOLERANCE)
end

-- Clears the move and returns false when the attacker or its wielded part
-- is no longer the one the move started with.
function CombatService:_check_attacker(player, state, session, active)
	if not is_active_attacker_valid(session, active) then
		self:_count(player, RejectReason.AttackerInvalid, active.WeaponId)
		clear_attack(state)
		return false
	end

	local wielded = self._weapons:GetWielded(player, active.Move.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		self:_count(player, RejectReason.WieldMismatch, active.WeaponId)
		clear_attack(state)
		return false
	end

	return true
end

function CombatService:_hit_start(player, move_id)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not active or active.MoveId ~= move_id then
		self:_count(player, RejectReason.NotActive, self:_equipped_id(player))
		return
	end

	if active.HitActive or active.PendingHitStart then
		self:_count(player, RejectReason.Duplicate, active.WeaponId)
		return
	end

	if not is_active_attacker_valid(session, active) then
		self:_count(player, RejectReason.AttackerInvalid, active.WeaponId)
		clear_attack(state)
		return
	end

	local now = self._scheduler.clock()
	if now > active.HitStartClosesAt then
		self:_count(player, RejectReason.LateHitStart, active.WeaponId)
		clear_attack(state)
		return
	end

	if not self:_check_attacker(player, state, session, active) then
		return
	end

	-- The client identifies the marker frame, but the hit cannot start before
	-- the definition's HitStartAt. An early HitStart is armed and activates
	-- exactly as an on-time one would, at the opening edge.
	if now < active.HitStartOpensAt then
		self:_count(player, RejectReason.EarlyHitStart, active.WeaponId)
		active.PendingHitStart = true
		active.CancelPendingHitStart = self._scheduler.after(active.HitStartOpensAt - now, function()
			self:_activate_pending(player, state, active)
		end)
		return
	end

	activate_hit(active, now)
end

function CombatService:_activate_pending(player, state, active)
	if state.Active ~= active or not active.PendingHitStart then
		return
	end
	active.PendingHitStart = false
	active.CancelPendingHitStart = nil

	local session = self._players:GetReady(player)
	if not self:_check_attacker(player, state, session, active) then
		return
	end

	activate_hit(active, active.HitStartOpensAt)
end

-- Seconds of the target's history the attacker may have been looking at.
function CombatService:_rewind(player)
	local ok, ping = pcall(player.GetNetworkPing, player)
	if not ok or typeof(ping) ~= "number" or not math.isfinite(ping) then
		ping = 0
	end
	return math.clamp(ping + LagCompensation.InterpolationDelay, 0, LagCompensation.MaxRewind)
end

function CombatService:_hit(player, move_id, hit_character, segment_instance, hit_position)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not active or active.MoveId ~= move_id or not active.HitActive then
		self:_count(player, RejectReason.NotActive, self:_equipped_id(player))
		return
	end

	local weapon_id = active.WeaponId
	local now = self._scheduler.clock()
	if now > active.ExpiresAt or now > active.HitExpiresAt then
		self:_count(player, RejectReason.Expired, weapon_id)
		clear_attack(state)
		return
	end

	if not is_active_attacker_valid(session, active) then
		self:_count(player, RejectReason.AttackerInvalid, weapon_id)
		clear_attack(state)
		return
	end

	-- Targets are table keys below; anything but an Instance is malformed.
	if typeof(hit_character) ~= "Instance" then
		self:_count(player, RejectReason.BadPayload, weapon_id)
		return
	end

	if active.HitTargets[hit_character] then
		self:_count(player, RejectReason.Duplicate, weapon_id)
		return
	end

	-- A target that already failed validation MaxRejectsPerTarget times is
	-- ignored without spending more raycasts on it.
	local rejected = active.Rejected[hit_character] or 0
	if rejected >= MAX_REJECTS_PER_TARGET
		or active.HitCount >= MAX_HITS_PER_ATTACK
		or active.HitRequests >= MAX_HIT_REQUESTS_PER_ATTACK then
		self:_count(player, RejectReason.RejectLimit, weapon_id)
		return
	end

	active.HitRequests += 1

	local hit_humanoid, reason, rewound = CombatValidation.ValidateHit(
		self._weapons,
		player,
		active,
		hit_character,
		segment_instance,
		hit_position,
		{
			History = if LagCompensation.Enabled then self._history else nil,
			Rewind = self:_rewind(player),
		}
	)

	if not hit_humanoid then
		active.Rejected[hit_character] = rejected + 1
		self:_count(player, reason or RejectReason.BadPayload, weapon_id)
		return
	end

	if rewound then
		self:_count(player, REWOUND, weapon_id)
	end

	active.HitTargets[hit_character] = true
	active.HitCount += 1

	local applied = self._damage:Apply({
		Source = { Model = active.Character, Player = player },
		Target = hit_character,
		Amount = active.Move.Damage,
		Kind = "Melee",
		WeaponId = weapon_id,
		MoveId = move_id,
		Position = hit_position,
	})

	if applied > 0 then
		self._remote:FireClient(player, CombatActions.HitConfirmed, move_id, hit_character)
	else
		self:_count(player, RejectReason.Blocked, weapon_id)
	end
end

function CombatService:_hit_stop(player, move_id)
	local state = self:_state(player)
	local active = state and state.Active
	if not active or active.MoveId ~= move_id then
		return
	end

	clear_attack(state)
end

function CombatService:_reset_attack_sequence(state)
	clear_attack(state)
	state.ComboIndex = 1
end

function CombatService:Destroy()
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return CombatService
