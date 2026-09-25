local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local CombatService = {}
CombatService.__index = CombatService

local ATTACK_REQUEST_INTERVAL = 0.1
local HIT_DISTANCE_MARGIN = 4
local ATTACK_TIMEOUT = 2

function CombatService.new(player_service, weapon_service, remote)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		WeaponService = weapon_service,
		Remote = remote,

		ActiveAttacks = {},
		NextAttack = {},
		LastAttackAt = {},
		PlayerTroves = {},
	}, CombatService)

	self:_start()

	return self
end

function CombatService:_start()
	self.Trove:Connect(
		self.Remote.OnServerEvent,
		function(player, action, attack_key, hit_character, segment_instance, hit_position)
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
	if self.ActiveAttacks[player] then
		return nil
	end

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
	local last_attack = self.LastAttackAt[player]

	if last_attack and now - last_attack < ATTACK_REQUEST_INTERVAL then
		return nil
	end

	return now
end

function CombatService:_create_active(player, attack_key, attack, wielded, character)
	local active = {
		AttackIndex = attack_key,
		Character = character,
		Attack = attack,
		Wielded = wielded,
		HitActive = false,
		HitTargets = {},
	}

	self.ActiveAttacks[player] = active

	if attack_key ~= "Charge" then
		task.delay(ATTACK_TIMEOUT, function()
			if self.ActiveAttacks[player] == active then
				self:_clear_attack(player)
			end
		end)
	end

	return active
end

function CombatService:_attack(player, attack_index)
	if typeof(attack_index) ~= "number" then
		return
	end

	local character, weapon = self:_get_attack_context(player)
	if not character then
		return
	end

	if self.ActiveAttacks[player] then
		return
	end

	local attack = weapon.Attacks and weapon.Attacks[attack_index]
	if not attack then
		return
	end

	local now = self:_can_begin_attack(player)
	if not now then
		return
	end

	if not self.LastAttackAt[player] then
		self.NextAttack[player] = 1
	end

	local expected_attack = self.NextAttack[player] or 1
	if attack_index ~= expected_attack then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, attack.Hitbox)
	if not wielded or wielded.Parent ~= character then
		return
	end

	self.LastAttackAt[player] = now
	self.NextAttack[player] = attack_index == #weapon.Attacks and 1 or attack_index + 1

	self:_create_active(
		player,
		attack_index,
		attack,
		wielded,
		character
	)
end

function CombatService:_charge(player)
	local character, weapon = self:_get_attack_context(player)
	if not character then
		return
	end

	if self.ActiveAttacks[player] then
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
	if not wielded or wielded.Parent ~= character then
		return
	end

	self.LastAttackAt[player] = now

	self:_create_active(
		player,
		"Charge",
		charge,
		wielded,
		character
	)
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
	if wielded ~= active.Wielded or wielded.Parent ~= active.Character then
		self:_clear_attack(player)
		return
	end

	active.HitActive = true
end

function CombatService:_hit(player, attack_key, hit_character, segment_instance, hit_position)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_key or not active.HitActive then
		return
	end

	if typeof(hit_character) ~= "Instance" or not hit_character:IsA("Model") then
		return
	end

	if segment_instance ~= nil then
		if typeof(segment_instance) ~= "Instance" or not segment_instance:IsA("Attachment") then
			return
		end
	end

	if hit_position ~= nil and typeof(hit_position) ~= "Vector3" then
		return
	end

	if hit_character == active.Character or not hit_character:IsDescendantOf(Workspace) then
		return
	end

	if active.HitTargets[hit_character] then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, active.Attack.Hitbox)
	if wielded ~= active.Wielded or wielded.Parent ~= active.Character then
		return
	end

	if segment_instance then
		if not segment_instance:IsDescendantOf(active.Wielded) then
			return
		end

		if not CollectionService:HasTag(segment_instance, "Hitpoint") then
			return
		end
	end

	local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
	local hit_root = hit_character:FindFirstChild("HumanoidRootPart")
	local attacker_root = active.Character:FindFirstChild("HumanoidRootPart")

	if not hit_humanoid or hit_humanoid.Health <= 0 or not hit_root or not attacker_root then
		return
	end

	local range = active.Attack.Range or 8

	if (hit_root.Position - attacker_root.Position).Magnitude > range + HIT_DISTANCE_MARGIN then
		return
	end

	if hit_position and (hit_root.Position - hit_position).Magnitude > range + HIT_DISTANCE_MARGIN then
		return
	end

	if segment_instance and hit_position and (segment_instance.WorldPosition - hit_position).Magnitude > HIT_DISTANCE_MARGIN then
		return
	end

	if hit_position then
		local raycast_params = RaycastParams.new()
		raycast_params.FilterType = Enum.RaycastFilterType.Exclude
		raycast_params.FilterDescendantsInstances = {active.Character}

		local origin = segment_instance and segment_instance.WorldPosition or attacker_root.Position
		local direction = hit_position - origin
		local result = Workspace:Raycast(origin, direction, raycast_params)

		if result and not result.Instance:IsDescendantOf(hit_character) then
			return
		end
	end

	active.HitTargets[hit_character] = true
	hit_humanoid:TakeDamage(active.Attack.Damage or 0)
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
	self.LastAttackAt[player] = nil
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
	table.clear(self.LastAttackAt)

	self.Trove:Destroy()
end

return CombatService
