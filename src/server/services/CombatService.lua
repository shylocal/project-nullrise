local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local CombatService = {}
CombatService.__index = CombatService

local HIT_DISTANCE_MARGIN = 4
local ATTACK_TIMEOUT = 2

function CombatService.new(player_service, weapon_service, remote)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,
		WeaponService = weapon_service,
		Remote = remote,
		ActiveAttacks = {},
	}, CombatService)

	self:_start()

	return self
end

function CombatService:_start()
	self.Trove:Connect(
		self.Remote.OnServerEvent,
		function(player, action, attack_index, hit_character)
			if action == "Attack" then
				self:_attack(player, attack_index)
			elseif action == "HitStart" then
				self:_hit_start(player, attack_index)
			elseif action == "Hit" then
				self:_hit(player, attack_index, hit_character)
			elseif action == "HitStop" then
				self:_hit_stop(player, attack_index)
			end
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerRemoving,
		function(player)
			self:_clear_attack(player)
		end
	)

	for _, player in self.PlayerService:GetPlayers() do
		self:_watch_player(player)
	end

	self.Trove:Connect(
		self.PlayerService.PlayerAdded,
		function(player)
			self:_watch_player(player)
		end
	)
end

function CombatService:_watch_player(player)
	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	self.Trove:Connect(
		session.CharacterRemoving,
		function(character)
			local active = self.ActiveAttacks[player]
			if active and active.Character == character then
				self:_clear_attack(player)
			end
		end
	)
end

function CombatService:_attack(player, attack_index)
	if typeof(attack_index) ~= "number" or attack_index % 1 ~= 0 then
		return
	end

	if self.ActiveAttacks[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session or not session.Character then
		return
	end

	local character = session.Character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local weapon = self.WeaponService:GetEquipped(player)
	local attack = weapon and weapon.Attacks and weapon.Attacks[attack_index]
	if not weapon or weapon.Type ~= "Melee" or not attack then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, attack.Hitbox)
	if not wielded then
		return
	end

	local active = {
		AttackIndex = attack_index,
		Character = character,
		Attack = attack,
		Hitbox = wielded,
		HitActive = false,
		HitTargets = {},
	}

	self.ActiveAttacks[player] = active

	task.delay(ATTACK_TIMEOUT, function()
		if self.ActiveAttacks[player] == active then
			self:_clear_attack(player)
		end
	end)
end

function CombatService:_hit_start(player, attack_index)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_index or active.HitActive then
		return
	end

	if active.Character.Parent == nil then
		self:_clear_attack(player)
		return
	end

	active.HitActive = true
end

function CombatService:_hit(player, attack_index, hit_character)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_index or not active.HitActive then
		return
	end

	if typeof(hit_character) ~= "Instance" or not hit_character:IsA("Model") then
		return
	end

	if hit_character == active.Character or not hit_character:IsDescendantOf(Workspace) then
		return
	end

	if active.HitTargets[hit_character] then
		return
	end

	local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
	local hit_root = hit_character:FindFirstChild("HumanoidRootPart")
	local attacker_root = active.Character:FindFirstChild("HumanoidRootPart")

	if not hit_humanoid or hit_humanoid.Health <= 0 or not hit_root or not attacker_root then
		return
	end

	local attack = active.Attack
	local range = attack.Range or 8

	if (hit_root.Position - attacker_root.Position).Magnitude > range + HIT_DISTANCE_MARGIN then
		return
	end

	active.HitTargets[hit_character] = true
	hit_humanoid:TakeDamage(attack.Damage or 0)
end

function CombatService:_hit_stop(player, attack_index)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_index then
		return
	end

	self:_clear_attack(player)
end

function CombatService:_clear_attack(player)
	self.ActiveAttacks[player] = nil
end

function CombatService:Destroy()
	table.clear(self.ActiveAttacks)
	self.Trove:Destroy()
end

return CombatService
