--!strict
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
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local RemoteBudget = require(script.Parent.Parent.network.RemoteBudget)
local CombatValidation = require(script.Parent.CombatValidation)
local DamageService = require(script.Parent.DamageService)
local MoveKinds = require(script.Parent.MoveKinds)
local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)
local PositionHistory = require(script.Parent.PositionHistory)

-- Studio-only reject diagnostics (Config.Combat.LogRejectsInStudio).
local LOG_REJECTS = game:GetService("RunService"):IsStudio() and Config.Combat.LogRejectsInStudio
local DEBUG_FIELDS = {
	"Reach", "ReachWithLead", "ReachLimit", "BodyDistance", "HitpointOffset",
	"HitpointOffsetWithLead", "Tolerance", "Lead", "Rewind", "FacingDot",
}
local Telemetry = require(script.Parent.Telemetry)
local WeaponService = require(script.Parent.WeaponService)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession
type WeaponDefinition = Catalog.WeaponDefinition
type MoveDef = Catalog.MoveDef
type Reason = RejectReason.Reason

-- A Hit that arrived while its move's HitStart was armed but not yet open.
-- Only payload-validated arguments are buffered.
type PendingHit = { Target: Model, Segment: Attachment, Position: Vector3 }

-- The move a player is performing. Field names are read by specs.
export type ActiveMove = {
	MoveId: number,
	Move: MoveDef,
	Kind: MoveKinds.MoveKind,
	WeaponId: string,
	Character: Model,
	Wielded: Instance,
	HitActive: boolean,
	-- Set when the hit window opens.
	HitExpiresAt: number?,
	-- An early HitStart is armed and activates at HitStartOpensAt.
	PendingHitStart: boolean,
	CancelPendingHitStart: Scheduler.Cancel?,
	-- Hits received while armed, in arrival order, one per target.
	PendingHits: { PendingHit },
	HitTargets: { [Instance]: boolean },
	Rejected: { [Instance]: number },
	HitCount: number,
	HitRequests: number,
	ValidationRaycastParams: RaycastParams,
	StartedAt: number,
	HitStartOpensAt: number,
	HitStartClosesAt: number,
	ExpiresAt: number,
	CancelExpiry: Scheduler.Cancel?,
}

type State = {
	Active: ActiveMove?,
	-- 1-based cursor into the equipped weapon's Combo.
	ComboIndex: number,
	NextAttackAt: number?,
	-- When the last charge held past its HitStart marker was released.
	ChargeReleasedAt: number?,
	LastThrottledRejectAt: number,
	Destroy: (self: State) -> (),
}

export type CombatServiceDeps = {
	players: PlayerService,
	weapons: WeaponService.WeaponService,
	-- The Combat RemoteEvent (a FakeRemote in specs).
	remote: RemoteEvent,
	budget: RemoteBudget.RemoteBudget,
	telemetry: Telemetry.Telemetry,
	scheduler: Scheduler.Scheduler,
	damage: DamageService.DamageService,
	history: PositionHistory.PositionHistory,
}

local CombatActions = Protocol.Combat
local CombatConfig = Config.Combat
local LagCompensation = CombatConfig.LagCompensation

-- Move timing (HitStartAt, HitWindow, MinDuration, Hold.MaxHoldTime) comes
-- from the validated weapon definitions. The tolerance only absorbs jitter
-- between two packets sent by the same client.
local TIMING_TOLERANCE = CombatConfig.TimingTolerance
local MAX_HITS_PER_ATTACK = CombatConfig.MaxHitsPerAttack
-- Bounds the spatial validation work (raycasts) a single move can cause,
-- independently of how many of those hits are accepted. Also bounds the
-- hits buffered while a HitStart is armed.
local MAX_HIT_REQUESTS_PER_ATTACK = CombatConfig.MaxHitRequestsPerAttack
local MAX_REJECTS_PER_TARGET = CombatConfig.MaxRejectsPerTarget
local REJECT_REPLY_INTERVAL = CombatConfig.RejectReplyInterval

-- Telemetry reasons for outcomes that are not request rejects.
local REWOUND = "Rewound"

local function is_move_id(value: unknown): boolean
	if type(value) ~= "number" then
		return false
	end
	return math.isfinite(value) and value % 1 == 0
end

-- The move with this id on `weapon` (a catalog definition, or a copy of one).
local function move_of(weapon: WeaponDefinition, move_id: number): MoveDef?
	for _, move in weapon.Moves do
		if move.Id == move_id then
			return move
		end
	end
	return nil
end

-- True for a move named directly by the weapon's bindings (the Hold move, or
-- a Tap move when Tap is not the combo).
local function is_bound(weapon: WeaponDefinition, move: MoveDef): boolean
	local primary = weapon.Bindings.Primary
	return primary.Hold == move.Name or (primary.Tap ~= Validator.ComboTap and primary.Tap == move.Name)
end

-- The earliest HitStart of a Hold move started after a released charge, or
-- nil when there is no bound. The client ignores presses while a charge is
-- held, so the Hold move needs a fresh press held for its HoldTime after the
-- release, and its hit starts at its HitStartAt marker after that. The
-- previous move's MinDuration is anchored at that move's start and cannot
-- see a long hold, so without this a charge released just before its
-- MinDuration could be followed by a second charge's hit within a few frames.
-- One tolerance absorbs the jitter between the two HitStart packets.
local function hold_hit_opens_at(state: State, weapon: WeaponDefinition, move: MoveDef): number?
	local released_at = state.ChargeReleasedAt
	local hold = move.Hold
	if released_at == nil or hold == nil or weapon.Bindings.Primary.Hold ~= move.Name then
		return nil
	end
	return released_at + hold.HoldTime + move.HitStartAt - TIMING_TOLERANCE
end

local function clear_attack(state: State)
	local active = state.Active
	if not active then
		return
	end

	state.Active = nil
	table.clear(active.HitTargets)
	table.clear(active.Rejected)
	table.clear(active.PendingHits)

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

local function new_state(): State
	return {
		Active = nil,
		ComboIndex = 1,
		NextAttackAt = nil,
		ChargeReleasedAt = nil,
		LastThrottledRejectAt = -math.huge,
		Destroy = clear_attack,
	}
end

local function is_active_attacker_valid(session: PlayerSession?, active: ActiveMove): boolean
	if not session or session.Character ~= active.Character then
		return false
	end

	local character = active.Character
	if character.Parent == nil then
		return false
	end

	return CharacterQuery.is_alive(character:FindFirstChildOfClass("Humanoid"))
end

local function activate_hit(active: ActiveMove, now: number)
	active.HitActive = true
	-- A light move's hits close with the move; a charge's hit window starts
	-- at its release (this HitStart).
	active.HitExpiresAt = active.Kind.hit_expires_at(active.Move, active, now, TIMING_TOLERANCE)
end

local CombatService = {}
CombatService.__index = CombatService

type CombatServiceFields = {
	Trove: PlayerSession.Trove,

	_players: PlayerService,
	_weapons: WeaponService.WeaponService,
	_remote: RemoteEvent,
	_budget: RemoteBudget.RemoteBudget,
	_telemetry: Telemetry.Telemetry,
	_scheduler: Scheduler.Scheduler,
	_damage: DamageService.DamageService,
	_history: PositionHistory.PositionHistory,
}

export type CombatService = typeof(setmetatable({} :: CombatServiceFields, CombatService))

function CombatService.new(deps: CombatServiceDeps): CombatService
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

	local fields: CombatServiceFields = {
		Trove = Trove.new(),

		_players = deps.players,
		_weapons = deps.weapons,
		_remote = deps.remote,
		_budget = deps.budget,
		_telemetry = deps.telemetry,
		_scheduler = deps.scheduler,
		_damage = deps.damage,
		_history = deps.history,
	}
	local self = setmetatable(fields, CombatService)

	-- Remote arguments are untrusted and checked per action.
	self.Trove:Connect(
		self._remote.OnServerEvent,
		function(player: Player, action: unknown, move_id: unknown, hit_character: unknown, segment_instance: unknown, hit_position: unknown)
			self:_on_remote(player, action, move_id, hit_character, segment_instance, hit_position)
		end
	)

	self.Trove:Connect(self._weapons.EquippedChanged, function(player: Player)
		local state = self:_state(player)
		if state then
			self:_reset_attack_sequence(state)
		end
	end)

	deps.players:Register(self, "CombatService")

	return self
end

function CombatService.OnPlayerAdded(self: CombatService, session: PlayerSession)
	session:Set(self, new_state())
end

function CombatService.OnCharacterRemoving(self: CombatService, session: PlayerSession)
	local state = session:Get(self) :: State?
	if not state then
		return
	end

	self:_reset_attack_sequence(state)
	state.NextAttackAt = nil
	state.ChargeReleasedAt = nil
end

function CombatService.OnPlayerRemoving(self: CombatService, session: PlayerSession)
	session:Clear(self)
end

-- State of a Ready session; remote traffic is never acted on otherwise.
function CombatService._state(self: CombatService, player: Player): (State?, PlayerSession?)
	local session = self._players:GetReady(player)
	if not session then
		return nil, nil
	end
	return session:Get(self) :: State?, session
end

function CombatService._count(self: CombatService, player: Player, reason: Reason, weapon_id: string?, debug: { [string]: number }?)
	self._telemetry:Count(player, "Combat", reason, weapon_id)
	if LOG_REJECTS then
		local parts = {}
		if debug then
			for _, field in DEBUG_FIELDS do
				local value = debug[field]
				if value ~= nil then
					table.insert(parts, ("%s=%.2f"):format(field, value))
				end
			end
		end
		print(("[CombatDebug] %s %s: %s %s"):format(
			player.Name,
			tostring(weapon_id),
			reason,
			table.concat(parts, " ")
		))
	end
end

function CombatService._equipped_id(self: CombatService, player: Player): string?
	local weapon = self._weapons:GetEquipped(player)
	return weapon and weapon.Id
end

-- The combo move the server expects next, or nil without an equipped weapon.
function CombatService._next_combo_move_id(self: CombatService, player: Player, state: State?): number?
	local weapon = self._weapons:GetEquipped(player)
	if not state or not weapon or not Catalog.IsEquippable(weapon) then
		return nil
	end
	if state.ComboIndex > #weapon.Combo then
		state.ComboIndex = 1
	end
	return Catalog.ComboMoveId(weapon, state.ComboIndex)
end

function CombatService._on_remote(
	self: CombatService,
	player: Player,
	action: unknown,
	move_id: unknown,
	hit_character: unknown,
	segment_instance: unknown,
	hit_position: unknown
)
	if type(action) ~= "string" then
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
	local id = move_id :: number

	if action == CombatActions.HitStart then
		self:_hit_start(player, id)
	elseif action == CombatActions.HitStop then
		self:_hit_stop(player, id)
	else
		self:_hit(player, id, hit_character, segment_instance, hit_position)
	end
end

function CombatService._get_attack_context(
	self: CombatService,
	player: Player,
	session: PlayerSession
): (Model?, WeaponDefinition?)
	local character = session.Character
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not CharacterQuery.is_alive(humanoid) then
		return nil, nil
	end

	local weapon = self._weapons:GetEquipped(player)
	if not weapon or not Catalog.IsEquippable(weapon) then
		return nil, nil
	end

	return character, weapon
end

-- The current time when a new move may start, nil during the previous
-- move's MinDuration.
function CombatService._can_begin_attack(self: CombatService, state: State): number?
	local now = self._scheduler.clock()
	local next_attack_at = state.NextAttackAt

	-- Allow a small amount of network jitter so the client's local cooldown
	-- and the server's monotonic clock do not disagree on boundary frames.
	if next_attack_at and now + TIMING_TOLERANCE < next_attack_at then
		return nil
	end

	return now
end

function CombatService._create_active(
	self: CombatService,
	state: State,
	weapon: WeaponDefinition,
	move: MoveDef,
	wielded: Instance,
	character: Model,
	started_at: number
): ActiveMove
	local kind = MoveKinds[move.Kind]
	local timing = kind.create_timing(move, started_at, TIMING_TOLERANCE)

	local active: ActiveMove = {
		MoveId = move.Id,
		Move = move,
		Kind = kind,
		WeaponId = weapon.Id,
		Character = character,
		Wielded = wielded,
		HitActive = false,
		HitExpiresAt = nil,
		PendingHitStart = false,
		CancelPendingHitStart = nil,
		PendingHits = {},
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

function CombatService._reply_rejected(self: CombatService, player: Player, requested_move_id: number?, state: State?)
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
function CombatService._reply_throttled(self: CombatService, player: Player, requested_move_id: number?, state: State?)
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
function CombatService._request_attack(self: CombatService, player: Player, move_id: unknown, allowed: boolean)
	local state, session = self:_state(player)

	if not is_move_id(move_id) then
		self:_count(player, RejectReason.BadPayload, self:_equipped_id(player))
		self:_reply_throttled(player, nil, state)
		return
	end
	local id = move_id :: number

	if not allowed then
		self:_reply_throttled(player, id, state)
		return
	end

	if not state or not session or not self:_attack(player, session, state, id) then
		self:_reply_rejected(player, id, state)
	end
end

-- Returns true after sending AttackAccepted; the caller rejects otherwise.
-- The combo-expected move advances the combo cursor; a move bound directly in
-- Bindings (the Heavy hold) is accepted without touching it.
function CombatService._attack(self: CombatService, player: Player, session: PlayerSession, state: State, move_id: number): boolean
	local character, weapon = self:_get_attack_context(player, session)
	if not character or not weapon then
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

	local active = self:_create_active(state, weapon, move, wielded, character, now)
	local hold_opens_at = hold_hit_opens_at(state, weapon, move)
	if hold_opens_at then
		-- An earlier HitStart is armed until then, like any early HitStart.
		active.HitStartOpensAt = math.max(active.HitStartOpensAt, hold_opens_at)
	end
	self._remote:FireClient(
		player,
		CombatActions.AttackAccepted,
		move_id,
		self:_next_combo_move_id(player, state)
	)
	return true
end

-- Clears the move and returns false when the attacker or its wielded part
-- is no longer the one the move started with.
function CombatService._check_attacker(
	self: CombatService,
	player: Player,
	state: State,
	session: PlayerSession?,
	active: ActiveMove
): boolean
	if not is_active_attacker_valid(session, active) then
		self:_count(player, RejectReason.AttackerInvalid, active.WeaponId)
		clear_attack(state)
		return false
	end

	local wielded = self._weapons:GetWielded(player, active.Move.Hitbox)
	if wielded == nil or wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		self:_count(player, RejectReason.WieldMismatch, active.WeaponId)
		clear_attack(state)
		return false
	end

	return true
end

function CombatService._hit_start(self: CombatService, player: Player, move_id: number)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not state or not active or active.MoveId ~= move_id then
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

	local released_at = active.Kind.released_at(active.Move, active.StartedAt, now, TIMING_TOLERANCE)
	if released_at then
		state.ChargeReleasedAt = released_at
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

-- Opens an armed HitStart, then validates the hits buffered while it was
-- armed, in arrival order, exactly as if each had just arrived.
function CombatService._activate_pending(self: CombatService, player: Player, state: State, active: ActiveMove)
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

	local pending = table.clone(active.PendingHits)
	table.clear(active.PendingHits)
	for _, hit in pending do
		-- A buffered hit can clear the move (the attacker died, say); the
		-- rest of the buffer belongs to that move and is dropped with it.
		if state.Active ~= active then
			return
		end
		self:_validate_hit(player, state, self._players:GetReady(player), active, hit.Target, hit.Segment, hit.Position)
	end
end

-- Seconds of the target's history the attacker may have been looking at.
function CombatService._rewind(_self: CombatService, player: Player): number
	local ok, result = pcall(player.GetNetworkPing, player)
	local ping = if ok and type(result) == "number" and math.isfinite(result) then result else 0
	return math.clamp(ping + LagCompensation.InterpolationDelay, 0, LagCompensation.MaxRewind)
end

function CombatService._hit(
	self: CombatService,
	player: Player,
	move_id: number,
	hit_character: unknown,
	segment_instance: unknown,
	hit_position: unknown
)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not state or not active or active.MoveId ~= move_id then
		self:_count(player, RejectReason.NotActive, self:_equipped_id(player))
		return
	end

	if active.PendingHitStart then
		self:_buffer_hit(player, active, hit_character, segment_instance, hit_position)
		return
	end

	if not active.HitActive then
		self:_count(player, RejectReason.NotActive, self:_equipped_id(player))
		return
	end

	self:_validate_hit(player, state, session, active, hit_character, segment_instance, hit_position)
end

-- The client reports each target once per swing, so a Hit that overtakes the
-- opening edge of an armed HitStart is kept until the window opens instead
-- of being dropped. One entry per target, at most MaxHitRequestsPerAttack.
function CombatService._buffer_hit(
	self: CombatService,
	player: Player,
	active: ActiveMove,
	hit_character: unknown,
	segment_instance: unknown,
	hit_position: unknown
)
	local weapon_id = active.WeaponId
	if not CombatValidation.IsHitPayload(hit_character, segment_instance, hit_position) then
		self:_count(player, RejectReason.BadPayload, weapon_id)
		return
	end
	local target = hit_character :: Model

	local pending = active.PendingHits
	for _, hit in pending do
		if hit.Target == target then
			self:_count(player, RejectReason.Duplicate, weapon_id)
			return
		end
	end

	if #pending >= MAX_HIT_REQUESTS_PER_ATTACK then
		self:_count(player, RejectReason.RejectLimit, weapon_id)
		return
	end

	table.insert(pending, {
		Target = target,
		Segment = segment_instance :: Attachment,
		Position = hit_position :: Vector3,
	})
end

-- Validates one hit against an open hit window and applies its damage.
function CombatService._validate_hit(
	self: CombatService,
	player: Player,
	state: State,
	session: PlayerSession?,
	active: ActiveMove,
	hit_character: unknown,
	segment_instance: unknown,
	hit_position: unknown
)
	local weapon_id = active.WeaponId
	local now = self._scheduler.clock()
	local hit_expires_at = active.HitExpiresAt
	if now > active.ExpiresAt or hit_expires_at == nil or now > hit_expires_at then
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
	local target = hit_character :: Instance

	if active.HitTargets[target] then
		self:_count(player, RejectReason.Duplicate, weapon_id)
		return
	end

	-- A target that already failed validation MaxRejectsPerTarget times is
	-- ignored without spending more raycasts on it.
	local rejected = active.Rejected[target] or 0
	if rejected >= MAX_REJECTS_PER_TARGET
		or active.HitCount >= MAX_HITS_PER_ATTACK
		or active.HitRequests >= MAX_HIT_REQUESTS_PER_ATTACK then
		self:_count(player, RejectReason.RejectLimit, weapon_id)
		return
	end

	active.HitRequests += 1

	local debug: { [string]: number }? = if LOG_REJECTS then {} else nil
	local hit_humanoid, reason, rewound = CombatValidation.ValidateHit(
		-- WeaponService has the WieldLookup shape; the checker does not match
		-- metatable-backed classes against table types.
		self._weapons :: any,
		player,
		active,
		target,
		segment_instance,
		hit_position,
		{
			History = if LagCompensation.Enabled then self._history else nil,
			Rewind = self:_rewind(player),
			Debug = debug,
		}
	)

	if not hit_humanoid then
		active.Rejected[target] = rejected + 1
		self:_count(player, reason or RejectReason.BadPayload, weapon_id, debug)
		return
	end

	if rewound then
		self:_count(player, REWOUND, weapon_id)
	end

	-- ValidateHit only succeeds for a Model target with a finite position.
	local model = target :: Model
	local position = hit_position :: Vector3

	active.HitTargets[model] = true
	active.HitCount += 1

	local applied = self._damage:Apply({
		Source = { Model = active.Character, Player = player },
		Target = model,
		Amount = active.Move.Damage,
		Kind = "Melee",
		WeaponId = weapon_id,
		MoveId = active.MoveId,
		Position = position,
	})

	if applied > 0 then
		self._remote:FireClient(player, CombatActions.HitConfirmed, active.MoveId, model)
	else
		self:_count(player, RejectReason.Blocked, weapon_id)
	end
end

function CombatService._hit_stop(self: CombatService, player: Player, move_id: number)
	local state = self:_state(player)
	local active = state and state.Active
	if not state or not active or active.MoveId ~= move_id then
		return
	end

	clear_attack(state)
end

function CombatService._reset_attack_sequence(_self: CombatService, state: State)
	clear_attack(state)
	state.ComboIndex = 1
end

function CombatService.Destroy(self: CombatService)
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return CombatService
