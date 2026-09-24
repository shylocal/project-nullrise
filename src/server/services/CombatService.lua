local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local ShapecastHitbox = require(Packages.ShapecastHitbox)

local CombatService = {}
CombatService.__index = CombatService

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
		function(player, action, attack_index)
			if action == "Attack" then
				self:_attack(player, attack_index)
			elseif action == "HitStart" then
				self:_hit_start(player, attack_index)
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

	self.ActiveAttacks[player] = {
		AttackIndex = attack_index,
		Character = character,
		Attack = attack,
		Wielded = wielded,
		Hitbox = nil,
	}
end

function CombatService:_hit_start(player, attack_index)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_index or active.Hitbox then
		return
	end

	if active.Character.Parent == nil then
		self:_clear_attack(player)
		return
	end

	self:_start_hitbox(player, active)
end

function CombatService:_hit_stop(player, attack_index)
	local active = self.ActiveAttacks[player]
	if not active or active.AttackIndex ~= attack_index then
		return
	end

	if active.Hitbox then
		active.Hitbox:HitStop()
	end

	self.ActiveAttacks[player] = nil
end

function CombatService:_start_hitbox(player, active)
	local character = active.Character
	local attack = active.Attack
	local wielded = active.Wielded

	local raycast_params = RaycastParams.new()
	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = {character}

	local hitbox = ShapecastHitbox.new(wielded, raycast_params)
	hitbox.FilterPartsHit = true
	active.Hitbox = hitbox

	local hit_characters = {}

	hitbox:OnHit(function(raycast_result)
		local hit_part = raycast_result.Instance
		local hit_character = hit_part and hit_part:FindFirstAncestorOfClass("Model")
		if not hit_character or hit_character == character then
			return
		end

		if hit_characters[hit_character] then
			return
		end

		local hit_humanoid = hit_character:FindFirstChildOfClass("Humanoid")
		if not hit_humanoid or hit_humanoid.Health <= 0 then
			return
		end

		hit_characters[hit_character] = true
		hit_humanoid:TakeDamage(attack.Damage or 0)
	end)

	hitbox:OnStopped(function(clean_callbacks)
		clean_callbacks()
		table.clear(hit_characters)

		if self.ActiveAttacks[player] and self.ActiveAttacks[player].Hitbox == hitbox then
			self.ActiveAttacks[player] = nil
		end

		hitbox:Destroy()
	end)

	hitbox:HitStart()
end

function CombatService:_clear_attack(player)
	local active = self.ActiveAttacks[player]
	if not active then
		return
	end

	if active.Hitbox then
		active.Hitbox:HitStop()
	else
		self.ActiveAttacks[player] = nil
	end
end

function CombatService:Destroy()
	for player in pairs(self.ActiveAttacks) do
		self:_clear_attack(player)
	end

	table.clear(self.ActiveAttacks)
	self.Trove:Destroy()
end

return CombatService
