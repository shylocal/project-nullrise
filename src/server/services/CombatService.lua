local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local CombatValidation = require(script.Parent.CombatValidation)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local CombatConfig = require(ReplicatedStorage.shared.weapons.CombatConfig)
local CombatActions = Protocol.Combat

local CombatService = {}
CombatService.__index = CombatService

-- Attack timing (HitStartAt, HitWindow, MinDuration, MaxHoldTime) comes from
-- the validated weapon definitions. The tolerance only absorbs jitter between
-- two packets sent by the same client.
local TIMING_TOLERANCE = CombatConfig.TimingTolerance
local MAX_HITS_PER_ATTACK = 8
-- Bounds the spatial validation work (raycasts) a single attack can cause,
-- independently of how many of those hits are accepted.
local MAX_HIT_REQUESTS_PER_ATTACK = 32

-- Hit packets are deliberately not throttled here: the client sends one packet
-- per target, so two targets struck on the same frame arrive back to back.
-- They are bounded per attack by the active hit window, per-target dedupe,
-- MAX_HITS_PER_ATTACK and MAX_HIT_REQUESTS_PER_ATTACK instead.
local REMOTE_MIN_INTERVAL = {
	[CombatActions.Attack] = 0.08,
	[CombatActions.Charge] = 0.08,
	[CombatActions.HitStart] = 0.02,
	[CombatActions.HitStop] = 0.02,
}

local function is_attack_index(value)
	return typeof(value) == "number" and math.isfinite(value) and value % 1 == 0
end

local function expected_attack_index(self, player)
	return self.NextAttack[player] or 1
end

function CombatService.new(player_service, weapon_service, remote)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		WeaponService = weapon_service,
		Remote = remote,

		ActiveAttacks = {},
		NextAttack = {},
		NextAttackAt = {},
		RemoteAt = {},
		PlayerTroves = {},
	}, CombatService)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CombatService:_start()
	self.Trove:Connect(
		self.Remote.OnServerEvent,
		function(player, action, attack_key, hit_character, segment_instance, hit_position)
			if action == CombatActions.Attack then
				self:_request_attack(player, attack_key)
				return
			end

			if action == CombatActions.Hit then
				self:_hit(player, attack_key, hit_character, segment_instance, hit_position)
				return
			end

			if typeof(action) ~= "string" then
				return
			end

			local min_interval = REMOTE_MIN_INTERVAL[action]
			if not min_interval or not self:_allow_remote(player, action, min_interval) then
				return
			end

			if action == CombatActions.Charge then
				self:_charge(player)
			elseif action == CombatActions.HitStart then
				self:_hit_start(player, attack_key)
			elseif action == CombatActions.HitStop then
				self:_hit_stop(player, attack_key)
			end
		end
	)

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
		self.WeaponService.EquippedChanged,
		function(player)
			self:_reset_attack_sequence(player)
		end
	)

	for _, player in self.PlayerService:GetPlayers() do
		self:_watch_player(player)
	end
end

function CombatService:_allow_remote(player, action, min_interval)
	local now = os.clock()
	local remote_at = self.RemoteAt[player]

	if not remote_at then
		remote_at = {}
		self.RemoteAt[player] = remote_at
	end

	local last_at = remote_at[action]
	if last_at and now - last_at < min_interval then
		return false
	end

	remote_at[action] = now
	return true
end

function CombatService:_watch_player(player)
	if self.PlayerTroves[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	local player_trove = Trove.new()
	self.PlayerTroves[player] = player_trove

	player_trove:Connect(
		session.CharacterRemoving,
		function()
			self:_reset_player(player)
		end
	)
end

function CombatService:_get_attack_context(player)
	local session = self.PlayerService:Get(player)
	if not session or not session.Character then
		return nil
	end

	local character = session.Character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	local weapon = self.WeaponService:GetEquipped(player)
	if not weapon or weapon.Type ~= "Melee" then
		return nil
	end

	return character, weapon
end

function CombatService:_can_begin_attack(player)
	local now = os.clock()
	local next_attack_at = self.NextAttackAt[player]

	-- Allow a small amount of network jitter so the client's local cooldown
	-- and the server's monotonic clock do not disagree on boundary frames.
	if next_attack_at and now + TIMING_TOLERANCE < next_attack_at then
		return nil
	end

	return now
end

function CombatService:_create_active(player, attack_key, attack, wielded, character, started_at)
	local is_charge = attack_key == "Charge"

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
		Character = character,
		Attack = attack,
		Wielded = wielded,
		HitActive = false,
		HitExpiresAt = nil,
		HitTargets = {},
		HitCount = 0,
		HitRequests = 0,
		ValidationRaycastParams = RaycastParams.new(),
		StartedAt = started_at,
		HitStartOpensAt = started_at + attack.HitStartAt - TIMING_TOLERANCE,
		HitStartClosesAt = hit_start_closes_at,
		ExpiresAt = expires_at,
	}

	self.ActiveAttacks[player] = active

	task.delay(expires_at - started_at, function()
		if self.ActiveAttacks[player] == active then
			self:_clear_attack(player)
		end
	end)

	return active
end

function CombatService:_reject_attack(player, requested_attack_index)
	self.Remote:FireClient(
		player,
		CombatActions.AttackRejected,
		requested_attack_index,
		expected_attack_index(self, player)
	)
end

-- Every Attack request is answered with exactly one AttackAccepted or
-- AttackRejected, including rate-limited and malformed requests, so the
-- client never waits on a pending attack that the server silently dropped.
function CombatService:_request_attack(player, attack_index)
	if not is_attack_index(attack_index) then
		self:_reject_attack(player, nil)
		return
	end

	if not self:_allow_remote(player, CombatActions.Attack, REMOTE_MIN_INTERVAL[CombatActions.Attack])
		or not self:_attack(player, attack_index) then
		self:_reject_attack(player, attack_index)
	end
end

-- Returns true after sending AttackAccepted; the caller rejects otherwise.
function CombatService:_attack(player, attack_index)
	local character, weapon = self:_get_attack_context(player)
	if not character then
		return false
	end

	local attack = weapon.Attacks[attack_index]
	if not attack then
		return false
	end

	-- The previous attack's MinDuration (stored in NextAttackAt) is enforced
	-- here, so starting a new attack cannot be used to skip ahead of it.
	local now = self:_can_begin_attack(player)
	if not now then
		return false
	end

	if attack_index ~= expected_attack_index(self, player) then
		return false
	end

	local wielded = self.WeaponService:GetWielded(player, attack.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		return false
	end

	self:_clear_attack(player)

	self.NextAttack[player] = attack_index == #weapon.Attacks and 1 or attack_index + 1
	self.NextAttackAt[player] = math.max(self.NextAttackAt[player] or 0, now + attack.MinDuration)

	self:_create_active(player, attack_index, attack, wielded, character, now)
	self.Remote:FireClient(player, CombatActions.AttackAccepted, attack_index, self.NextAttack[player])
	return true
end

function CombatService:_charge(player)
	local character, weapon = self:_get_attack_context(player)
	if not character then
		return
	end

	local charge = weapon.Charge
	if not charge then
		return
	end

	local now = self:_can_begin_attack(player)
	if not now then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, charge.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		return
	end

	self:_clear_attack(player)
	self.NextAttackAt[player] = math.max(self.NextAttackAt[player] or 0, now + charge.MinDuration)

	self:_create_active(player, "Charge", charge, wielded, character, now)
end

local function is_active_attacker_valid(self, player, active)
	local session = self.PlayerService:Get(player)
	if not session or session.Character ~= active.Character then
		return false
	end

	local character = active.Character
	if not character or character.Parent == nil then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function CombatService:_hit_start(player, attack_key)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key or active.HitActive then
		return
	end

	local now = os.clock()
	if not is_active_attacker_valid(self, player, active) or now > active.HitStartClosesAt then
		self:_clear_attack(player)
		return
	end

	local wielded = self.WeaponService:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		self:_clear_attack(player)
		return
	end

	-- The client identifies the marker frame, but it cannot be earlier than the
	-- definition's HitStartAt. Early packets are ignored.
	if now < active.HitStartOpensAt then
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
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key or not active.HitActive then
		return
	end

	local now = os.clock()
	if now > active.ExpiresAt
		or now > active.HitExpiresAt
		or not is_active_attacker_valid(self, player, active) then
		self:_clear_attack(player)
		return
	end

	if active.HitTargets[hit_character]
		or active.HitCount >= MAX_HITS_PER_ATTACK
		or active.HitRequests >= MAX_HIT_REQUESTS_PER_ATTACK then
		return
	end

	active.HitRequests += 1

	local hit_humanoid = CombatValidation.ValidateHit(
		self.WeaponService,
		player,
		active,
		hit_character,
		segment_instance,
		hit_position
	)

	if not hit_humanoid then
		return
	end

	active.HitTargets[hit_character] = true
	active.HitCount += 1
	hit_humanoid:TakeDamage(active.Attack.Damage)
	self.Remote:FireClient(player, CombatActions.HitConfirmed, attack_key, hit_character)
end

function CombatService:_hit_stop(player, attack_key)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key then
		return
	end

	self:_clear_attack(player)
end

function CombatService:_clear_attack(player)
	local active = self.ActiveAttacks[player]

	if active then
		table.clear(active.HitTargets)
	end

	self.ActiveAttacks[player] = nil
end

function CombatService:_reset_attack_sequence(player)
	self:_clear_attack(player)
	self.NextAttack[player] = 1
end

function CombatService:_reset_player(player)
	self:_reset_attack_sequence(player)
	self.NextAttackAt[player] = nil
	self.RemoteAt[player] = nil
end

function CombatService:_player_removing(player)
	self:_clear_attack(player)
	self.NextAttack[player] = nil
	self.NextAttackAt[player] = nil
	self.RemoteAt[player] = nil

	local player_trove = self.PlayerTroves[player]
	if player_trove then
		player_trove:Destroy()
		self.PlayerTroves[player] = nil
	end
end

function CombatService:Destroy()
	for player in pairs(self.PlayerTroves) do
		self:_player_removing(player)
	end

	table.clear(self.PlayerTroves)
	table.clear(self.ActiveAttacks)
	table.clear(self.NextAttack)
	table.clear(self.NextAttackAt)
	table.clear(self.RemoteAt)

	self.Trove:Destroy()
end

return CombatService
