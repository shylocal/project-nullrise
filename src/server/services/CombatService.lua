-- Authoritative melee combat. Each player's attack sequence and active attack
-- are PlayerService component state. Every inbound Combat action is charged
-- against the RemoteBudget first; every dropped request is counted in
-- Telemetry with a RejectReason.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local CombatValidation = require(script.Parent.CombatValidation)

local CombatActions = Protocol.Combat
local CombatConfig = Config.Combat

-- Attack timing (HitStartAt, HitWindow, MinDuration, MaxHoldTime) comes from
-- the validated weapon definitions. The tolerance only absorbs jitter between
-- two packets sent by the same client.
local TIMING_TOLERANCE = CombatConfig.TimingTolerance
local MAX_HITS_PER_ATTACK = CombatConfig.MaxHitsPerAttack
-- Bounds the spatial validation work (raycasts) a single attack can cause,
-- independently of how many of those hits are accepted.
local MAX_HIT_REQUESTS_PER_ATTACK = CombatConfig.MaxHitRequestsPerAttack
local MAX_REJECTS_PER_TARGET = CombatConfig.MaxRejectsPerTarget
local REJECT_REPLY_INTERVAL = CombatConfig.RejectReplyInterval

local CHARGE_KEY = "Charge"

local function is_attack_index(value)
	return typeof(value) == "number" and math.isfinite(value) and value % 1 == 0
end

local function is_attack_key(value)
	return value == CHARGE_KEY or is_attack_index(value)
end

local CombatService = {}
CombatService.__index = CombatService

function CombatService.new(deps)
	Deps.check(deps, "CombatService", { "players", "weapons", "remote", "budget", "telemetry", "scheduler" })

	local self = setmetatable({
		Trove = Trove.new(),

		_players = deps.players,
		_weapons = deps.weapons,
		_remote = deps.remote,
		_budget = deps.budget,
		_telemetry = deps.telemetry,
		_scheduler = deps.scheduler,
	}, CombatService)

	self.Trove:Connect(
		self._remote.OnServerEvent,
		function(player, action, attack_key, hit_character, segment_instance, hit_position)
			self:_on_remote(player, action, attack_key, hit_character, segment_instance, hit_position)
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

	local cancel = active.CancelExpiry
	active.CancelExpiry = nil
	if cancel then
		cancel()
	end
end

local function new_state()
	return {
		Active = nil,
		NextAttack = 1,
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

function CombatService:_on_remote(player, action, attack_key, hit_character, segment_instance, hit_position)
	if typeof(action) ~= "string" then
		self._telemetry:Count(player, "Network", RejectReason.BadPayload, "Combat")
		return
	end

	local allowed = self._budget:Take(player, "Combat." .. action)

	if action == CombatActions.Attack then
		self:_request_attack(player, attack_key, allowed)
		return
	end

	if not allowed then
		return
	end

	if action == CombatActions.Charge then
		self:_charge(player)
		return
	end

	if action ~= CombatActions.HitStart and action ~= CombatActions.HitStop and action ~= CombatActions.Hit then
		return
	end

	if not is_attack_key(attack_key) then
		self:_count(player, RejectReason.BadPayload, self:_equipped_id(player))
		return
	end

	if action == CombatActions.HitStart then
		self:_hit_start(player, attack_key)
	elseif action == CombatActions.HitStop then
		self:_hit_stop(player, attack_key)
	else
		self:_hit(player, attack_key, hit_character, segment_instance, hit_position)
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

function CombatService:_create_active(state, weapon, attack_key, attack, wielded, character, started_at)
	local is_charge = attack_key == CHARGE_KEY

	-- A light attack's hits must land within HitWindow of its HitStart marker.
	-- A charge may be held until MaxHoldTime, and its hit window starts when it
	-- is released (HitStart), so its lifetime extends past the longest hold.
	local hit_start_closes_at
	local expires_at
	if is_charge then
		hit_start_closes_at = started_at + attack.MaxHoldTime + TIMING_TOLERANCE
		expires_at = hit_start_closes_at + attack.HitWindow
	else
		hit_start_closes_at = started_at + attack.HitStartAt + attack.HitWindow + TIMING_TOLERANCE
		expires_at = hit_start_closes_at
	end

	local active = {
		AttackIndex = attack_key,
		IsCharge = is_charge,
		WeaponId = weapon.Id,
		Character = character,
		Attack = attack,
		Wielded = wielded,
		HitActive = false,
		HitExpiresAt = nil,
		HitTargets = {},
		Rejected = {},
		HitCount = 0,
		HitRequests = 0,
		ValidationRaycastParams = RaycastParams.new(),
		StartedAt = started_at,
		HitStartOpensAt = started_at + attack.HitStartAt - TIMING_TOLERANCE,
		HitStartClosesAt = hit_start_closes_at,
		ExpiresAt = expires_at,
		CancelExpiry = nil,
	}

	clear_attack(state)
	state.Active = active

	active.CancelExpiry = self._scheduler.after(expires_at - started_at, function()
		if state.Active == active then
			clear_attack(state)
		end
	end)

	return active
end

function CombatService:_reply_rejected(player, requested_attack_index, state)
	self._remote:FireClient(
		player,
		CombatActions.AttackRejected,
		requested_attack_index,
		state and state.NextAttack or 1
	)
end

-- Malformed and budget-dropped Attack requests are answered at most once per
-- RejectReplyInterval, so a flood of bad requests cannot be amplified into a
-- flood of replies. The client's pending-attack timeout covers the rest.
function CombatService:_reply_throttled(player, requested_attack_index, state)
	if not state then
		return
	end

	local now = self._scheduler.clock()
	if now - state.LastThrottledRejectAt < REJECT_REPLY_INTERVAL then
		return
	end

	state.LastThrottledRejectAt = now
	self:_reply_rejected(player, requested_attack_index, state)
end

-- Every well-formed Attack request that passes the budget is answered with
-- exactly one AttackAccepted or AttackRejected.
function CombatService:_request_attack(player, attack_index, allowed)
	local state, session = self:_state(player)

	if not is_attack_index(attack_index) then
		self:_count(player, RejectReason.BadPayload, self:_equipped_id(player))
		self:_reply_throttled(player, nil, state)
		return
	end

	if not allowed then
		self:_reply_throttled(player, attack_index, state)
		return
	end

	if not state or not self:_attack(player, session, state, attack_index) then
		self:_reply_rejected(player, attack_index, state)
	end
end

-- Returns true after sending AttackAccepted; the caller rejects otherwise.
function CombatService:_attack(player, session, state, attack_index)
	local character, weapon = self:_get_attack_context(player, session)
	if not character then
		self:_count(player, RejectReason.AttackerInvalid, self:_equipped_id(player))
		return false
	end

	local attack = weapon.Attacks[attack_index]
	if not attack then
		self:_count(player, RejectReason.BadPayload, weapon.Id)
		return false
	end

	-- The previous attack's MinDuration (stored in NextAttackAt) is enforced
	-- here, so starting a new attack cannot be used to skip ahead of it.
	local now = self:_can_begin_attack(state)
	if not now then
		return false
	end

	if attack_index ~= state.NextAttack then
		return false
	end

	local wielded = self._weapons:GetWielded(player, attack.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		self:_count(player, RejectReason.WieldMismatch, weapon.Id)
		return false
	end

	state.NextAttack = attack_index == #weapon.Attacks and 1 or attack_index + 1
	state.NextAttackAt = math.max(state.NextAttackAt or 0, now + attack.MinDuration)

	self:_create_active(state, weapon, attack_index, attack, wielded, character, now)
	self._remote:FireClient(player, CombatActions.AttackAccepted, attack_index, state.NextAttack)
	return true
end

function CombatService:_charge(player)
	local state, session = self:_state(player)
	if not state then
		return
	end

	local character, weapon = self:_get_attack_context(player, session)
	if not character then
		self:_count(player, RejectReason.AttackerInvalid, self:_equipped_id(player))
		return
	end

	local charge = weapon.Charge
	if not charge then
		self:_count(player, RejectReason.BadPayload, weapon.Id)
		return
	end

	local now = self:_can_begin_attack(state)
	if not now then
		return
	end

	local wielded = self._weapons:GetWielded(player, charge.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		self:_count(player, RejectReason.WieldMismatch, weapon.Id)
		return
	end

	state.NextAttackAt = math.max(state.NextAttackAt or 0, now + charge.MinDuration)

	self:_create_active(state, weapon, CHARGE_KEY, charge, wielded, character, now)
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

function CombatService:_hit_start(player, attack_key)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not active or active.AttackIndex ~= attack_key then
		self:_count(player, RejectReason.NotActive, self:_equipped_id(player))
		return
	end

	if active.HitActive then
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

	local wielded = self._weapons:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		self:_count(player, RejectReason.WieldMismatch, active.WeaponId)
		clear_attack(state)
		return
	end

	-- The client identifies the marker frame, but it cannot be earlier than the
	-- definition's HitStartAt. Early packets are ignored.
	if now < active.HitStartOpensAt then
		self:_count(player, RejectReason.EarlyHitStart, active.WeaponId)
		return
	end

	active.HitActive = true
	if active.IsCharge then
		-- A charge's hit window starts at its release, not at the charge start.
		active.HitExpiresAt = math.min(active.ExpiresAt, now + active.Attack.HitWindow + TIMING_TOLERANCE)
	else
		active.HitExpiresAt = active.ExpiresAt
	end
end

function CombatService:_hit(player, attack_key, hit_character, segment_instance, hit_position)
	local state, session = self:_state(player)
	local active = state and state.Active
	if not active or active.AttackIndex ~= attack_key or not active.HitActive then
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

	local hit_humanoid, reason = CombatValidation.ValidateHit(
		self._weapons,
		player,
		active,
		hit_character,
		segment_instance,
		hit_position
	)

	if not hit_humanoid then
		active.Rejected[hit_character] = rejected + 1
		self:_count(player, reason or RejectReason.BadPayload, weapon_id)
		return
	end

	active.HitTargets[hit_character] = true
	active.HitCount += 1
	hit_humanoid:TakeDamage(active.Attack.Damage)
	self._remote:FireClient(player, CombatActions.HitConfirmed, attack_key, hit_character)
end

function CombatService:_hit_stop(player, attack_key)
	local state = self:_state(player)
	local active = state and state.Active
	if not active or active.AttackIndex ~= attack_key then
		return
	end

	clear_attack(state)
end

function CombatService:_reset_attack_sequence(state)
	clear_attack(state)
	state.NextAttack = 1
end

function CombatService:Destroy()
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end

	self.Trove:Destroy()
end

return CombatService
