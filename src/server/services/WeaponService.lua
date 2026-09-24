local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local WeaponModels = ReplicatedStorage.weapon_models
local WeaponRemote = ReplicatedStorage.remotes.Weapon
local Fists = require(WeaponsFolder.Fists)

local WeaponService = {}
WeaponService.__index = WeaponService

function WeaponService.new(player_service)
	local self = setmetatable({
		Trove = Trove.new(),
		PlayerService = player_service,

		Equipped = {},
		CharacterTroves = {},
		PlayerTroves = {},
		Wielded = {},

		EquippedChanged = Signal.new(),
	}, WeaponService)

	self.Trove:Add(self.EquippedChanged)
	self:_start()

	return self
end

function WeaponService:_start()
	self.Trove:Connect(
		WeaponRemote.OnServerEvent,
		function(player, action, weapon_id)
			if action == "Equip" then
				self:Equip(player, weapon_id)
			end
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerAdded,
		function(player)
			self:_player_added(player)
		end
	)

	self.Trove:Connect(
		self.PlayerService.PlayerRemoving,
		function(player)
			self:_player_removing(player)
		end
	)

	for _, player in self.PlayerService:GetPlayers() do
		self:_player_added(player)
	end
end

function WeaponService:_player_added(player)
	if self.Equipped[player] then
		return
	end

	local session = self.PlayerService:Get(player)
	if not session then
		return
	end

	local player_trove = Trove.new()
	self.PlayerTroves[player] = player_trove

	self.Equipped[player] = Fists

	player_trove:Connect(
		session.CharacterAdded,
		function(character)
			self:_character_added(player, character)
		end
	)

	player_trove:Connect(
		session.CharacterRemoving,
		function(character)
			self:_character_removing(player, character)
		end
	)

	if session.Character then
		self:_character_added(player, session.Character)
	end
end

function WeaponService:_character_added(player, character)
	self:_clear_character(player)

	local weapon = self.Equipped[player]
	if not weapon then
		return
	end

	local character_trove = Trove.new()

	self.CharacterTroves[player] = character_trove
	self.Wielded[player] = {}

	self:_attach_weapon(player, character, weapon, character_trove)
end

function WeaponService:_character_removing(player, character)
	local session = self.PlayerService:Get(player)
	if session and session.Character == character then
		self:_clear_character(player)
	end
end

function WeaponService:_clear_character(player)
	local character_trove = self.CharacterTroves[player]

	if character_trove then
		character_trove:Destroy()
		self.CharacterTroves[player] = nil
	end

	self.Wielded[player] = nil
end

function WeaponService:_attach_weapon(player, character, weapon, character_trove)
	local model = WeaponModels:FindFirstChild(weapon.Model)
	if not model then
		return
	end

	for wield_name, character_part_name in pairs(weapon.Wield or {}) do
		local source = model:FindFirstChild(wield_name)
		local target = character:FindFirstChild(character_part_name, true)

		if not source or not target or not target:IsA("BasePart") then
			continue
		end

		local clone = source:Clone()
		clone.Parent = character

		local root = self:_prepare_model(clone, target)
		if not root then
			clone:Destroy()
			continue
		end

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = target
		weld.Part1 = root
		weld.Parent = root

		self:_tag_hitpoints(clone)

		character_trove:Add(clone)
		self.Wielded[player][wield_name] = clone
	end
end

function WeaponService:_tag_hitpoints(instance)
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == "Hitpoint" then
			CollectionService:AddTag(descendant, "DmgPoint")
		end
	end
end

function WeaponService:_prepare_model(instance, target)
	if instance:IsA("BasePart") then
		instance.CFrame = target.CFrame
		instance.Anchored = false
		instance.CanCollide = false
		instance.Massless = true

		return instance
	end

	if not instance:IsA("Model") then
		return nil
	end

	local root = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	if not root then
		return nil
	end

	instance:PivotTo(target.CFrame)

	for _, descendant in instance:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end

		descendant.Anchored = false
		descendant.CanCollide = false
		descendant.Massless = true

		if descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	return root
end

function WeaponService:GetEquipped(player)
	return self.Equipped[player]
end

function WeaponService:GetWielded(player, wield_name)
	local wielded = self.Wielded[player]
	return wielded and wielded[wield_name]
end

function WeaponService:Equip(player, weapon_id)
	if typeof(weapon_id) ~= "string" then
		return false
	end

	if not self.PlayerService:Get(player) then
		return false
	end

	local weapon_module = WeaponsFolder:FindFirstChild(weapon_id)
	if not weapon_module or not weapon_module:IsA("ModuleScript") then
		return false
	end

	local weapon = require(weapon_module)
	if not weapon or weapon.Type ~= "Melee" or not weapon.Model then
		return false
	end

	if not WeaponModels:FindFirstChild(weapon.Model) then
		return false
	end

	local current = self.Equipped[player]
	if current == weapon then
		WeaponRemote:FireClient(player, "Equipped", weapon_id)
		return true
	end

	self.Equipped[player] = weapon

	local session = self.PlayerService:Get(player)
	if session and session.Character then
		self:_character_added(player, session.Character)
	end

	self.EquippedChanged:Fire(player, weapon)
	WeaponRemote:FireClient(player, "Equipped", weapon_id)

	return true
end

function WeaponService:_player_removing(player)
	self:_clear_character(player)

	local player_trove = self.PlayerTroves[player]
	if player_trove then
		player_trove:Destroy()
		self.PlayerTroves[player] = nil
	end

	self.Equipped[player] = nil
end

function WeaponService:Destroy()
	for player in pairs(self.PlayerTroves) do
		self:_player_removing(player)
	end

	for player in pairs(self.CharacterTroves) do
		self:_clear_character(player)
	end

	table.clear(self.PlayerTroves)
	table.clear(self.CharacterTroves)
	table.clear(self.Wielded)
	table.clear(self.Equipped)

	self.Trove:Destroy()
end

return WeaponService
