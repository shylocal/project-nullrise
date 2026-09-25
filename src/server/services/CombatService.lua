local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local CombatValidation = require(script.Parent.CombatValidation)

local CombatService = {}
CombatService.__index = CombatService

local ATTACK_TIMEOUT = 2
local CHARGE_TIMEOUT = 10
local TIMING_TOLERANCE = 0.05

local REMOTE_MIN_INTERVAL = {
	Attack = 0.08,
	Charge = 0.08,
	HitStart = 0.02,
	Hit = 0.02,
	HitStop = 0.02,
}

local function is_valid_duration(value)
	return typeof(value) == "number" and math.isfinite(value) and value >= 0
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

	self:_start()

	return self
end

function CombatService:_start()
	self.Trove:Connect(
		self.Remote.OnServerEvent,
		function(player, action, attack_key, hit_character, segment_instance, hit_position)
			if typeof(action) ~= "string" then
				return
			end

			local min_interval = REMOTE_MIN_INTERVAL[action]
			if not min_interval or not self:_allow_remote(player, action, min_interval) then
				return
			end

			if action == "Attack" then
				self:_attack(player, attack_key)
			elseif action == "Charge" then
				self:_charge(player)
			elseif action == "HitStart" then
				self:_hit_start(player, attack_key)
			elseif action == "Hit" then
				self:_hit(player, attack_key, hit_character, segment_instance, hit_position)
			elseif action == "HitStop" then
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
			self:_reset_player(player)
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

function CombatService:_get_attack_timing(attack, is_charge)
	local cooldown = attack.Cooldown
	if not is_valid_duration(cooldown) or cooldown <= 0 then
		return nil
	end

	if not is_charge then
		return {
			Cooldown = cooldown,
		}
	end

	local ready_time = attack.HoldTime
	if ready_time == nil then
		ready_time = 0.15
	end

	if not is_valid_duration(ready_time) then
		return nil
	end

	return {
		Cooldown = cooldown,
		ReadyTime = ready_time,
	}
end

function CombatService:_can_begin_attack(player)
	local now = os.clock()
	local next_attack_at = self.NextAttackAt[player]

	if next_attack_at and now < next_attack_at then
		return nil
	end

	return now
end

function CombatService:_create_active(player, attack_key, attack, timing, wielded, character)
	local started_at = os.clock()
	local lifetime = attack_key == "Charge" and CHARGE_TIMEOUT or timing.Cooldown
	local expires_at = started_at + lifetime + ATTACK_TIMEOUT

	local active = {
		AttackIndex = attack_key,
		Character = character,
		Attack = attack,
		Timing = timing,
		Wielded = wielded,
		HitActive = false,
		HitTargets = {},
		StartedAt = started_at,
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

function CombatService:_attack(player, attack_index)
	if typeof(attack_index) ~= "number" or not math.isfinite(attack_index) or attack_index % 1 ~= 0 then
		return
	end

	local character, weapon = self:_get_attack_context(player)
	if not character then
		return
	end

	local attack = weapon.Attacks and weapon.Attacks[attack_index]
	if not attack then
		return
	end

	local timing = self:_get_attack_timing(attack, false)
	if not timing then
		return
	end

	local now = self:_can_begin_attack(player)
	if not now then
		return
	end

	local expected_attack = self.NextAttack[player] or 1
	if attack_index ~= expected_attack then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, attack.Hitbox)
	if not wielded or not wielded:IsDescendantOf(character) then
		return
	end

	self:_clear_attack(player)

	self.NextAttack[player] = attack_index == #weapon.Attacks and 1 or attack_index + 1
	self.NextAttackAt[player] = now + timing.Cooldown

	self:_create_active(player, attack_index, attack, timing, wielded, character)
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

	local timing = self:_get_attack_timing(charge, true)
	if not timing then
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
	self.NextAttackAt[player] = now + timing.Cooldown

	self:_create_active(player, "Charge", charge, timing, wielded, character)
end

function CombatService:_hit_start(player, attack_key)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key or active.HitActive then
		return
	end

	if active.Character.Parent == nil then
		self:_clear_attack(player)
		return
	end

	local wielded = self.WeaponService:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or not wielded:IsDescendantOf(active.Character) then
		self:_clear_attack(player)
		return
	end

	local now = os.clock()
	if attack_key == "Charge" then
		local ready_at = active.StartedAt + active.Timing.ReadyTime
		if now + TIMING_TOLERANCE < ready_at then
			return
		end
	elseif now + TIMING_TOLERANCE < active.StartedAt then
		return
	end

	if now > active.ExpiresAt - ATTACK_TIMEOUT + TIMING_TOLERANCE then
		return
	end

	-- Animation markers define the hitbox window; Cooldown remains the only
	-- weapon timing that controls when another attack may be initiated.
	active.HitActive = true
end

function CombatService:_hit(player, attack_key, hit_character, segment_instance, hit_position)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key or not active.HitActive then
		return
	end

	if active.HitTargets[hit_character] then
		return
	end

	local damage = active.Attack.Damage
	if typeof(damage) ~= "number" or not math.isfinite(damage) or damage < 0 then
		return
	end

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
	hit_humanoid:TakeDamage(damage)
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

function CombatService:_reset_player(player)
	self:_clear_attack(player)
	self.NextAttack[player] = 1
	self.NextAttackAt[player] = nil
	self.RemoteAt[player] = nil
end

function CombatService:_player_removing(player)
	self:_reset_player(player)

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
