local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

local CLIMBABLE_COLLISION_GROUP = "Climbable"

if not PhysicsService:IsCollisionGroupRegistered(CLIMBABLE_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(CLIMBABLE_COLLISION_GROUP)
end

local PlayerService = require(script.services.PlayerService)
local InventoryService = require(script.services.InventoryService)
local WeaponService = require(script.services.WeaponService)
local CombatService = require(script.services.CombatService)
local MovementValidation = require(script.services.MovementValidation)

local CombatRemote = ReplicatedStorage.remotes.Combat

local player_service
local inventory_service
local weapon_service
local combat_service
local movement_validation

local ok, err = pcall(function()
	player_service = PlayerService.new()
	inventory_service = InventoryService.new(player_service)
	weapon_service = WeaponService.new(player_service, inventory_service)
	combat_service = CombatService.new(player_service, weapon_service, CombatRemote)
	movement_validation = MovementValidation.new(player_service)
end)

if not ok then
	if movement_validation then movement_validation:Destroy() end
	if combat_service then combat_service:Destroy() end
	if weapon_service then weapon_service:Destroy() end
	if inventory_service then inventory_service:Destroy() end
	if player_service then player_service:Destroy() end
	error(err, 0)
end

local runtime = {
	PlayerService = player_service,
	InventoryService = inventory_service,
	WeaponService = weapon_service,
	CombatService = combat_service,
	MovementValidation = movement_validation,
	_destroyed = false,
}

-- Shut down consumers before the services they depend on.
function runtime:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self.MovementValidation:Destroy()
	self.CombatService:Destroy()
	self.WeaponService:Destroy()
	self.InventoryService:Destroy()
	self.PlayerService:Destroy()
end

script.Destroying:Connect(function()
	runtime:Destroy()
end)
