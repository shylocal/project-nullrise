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
		Cooldowns = {},
	}, CombatService)

	self:_start()

	return self
end

function CombatService:_start()
	self.Trove:Connect(
		self.Remote.OnServerEvent,
		function(player, attack_index)
			self:_attack(player, attack_index)
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerRemoving,
		function(player)
			self.Cooldowns[player] = nil
		end
	)
end

function CombatService:_attack(player, attack_index)
	if typeof(attack_index) ~= "number" or attack_index % 1 ~= 0 then
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

	local now = os.clock()
	if now < (self.Cooldowns[player] or 0) then
		return
	end

	local wielded = self.WeaponService:GetWielded(player, attack.Hitbox)
	if not wielded then
		return
	end

	self.Cooldowns[player] = now + (attack.Cooldown or 0.35)
	self:_start_hitbox(character, wielded, attack)
end

function CombatService:_start_hitbox(character, wielded, attack)
	local raycast_params = RaycastParams.new()
	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = {character}

	local hitbox = ShapecastHitbox.new(wielded, raycast_params)
	hitbox.FilterPartsHit = true

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

	hitbox:HitStart(attack.HitboxDuration or 0.15):OnStopped(function(clean_callbacks)
		clean_callbacks()
		table.clear(hit_characters)
		hitbox:Destroy()
	end)
end

function CombatService:Destroy()
	table.clear(self.Cooldowns)
	self.Trove:Destroy()
end

return CombatService
