local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerService = require(script.services.PlayerService)
local InventoryService = require(script.services.InventoryService)
local WeaponService = require(script.services.WeaponService)
local CombatService = require(script.services.CombatService)

local CombatRemote = ReplicatedStorage.remotes.Combat

local player_service
local inventory_service
local weapon_service
local combat_service

local ok, err = pcall(function()
	player_service = PlayerService.new()
	inventory_service = InventoryService.new(player_service)
	weapon_service = WeaponService.new(player_service, inventory_service)
	combat_service = CombatService.new(player_service, weapon_service, CombatRemote)
end)

if not ok then
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
	_destroyed = false,
}

-- Shut down consumers before the services they depend on.
function runtime:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self.CombatService:Destroy()
	self.WeaponService:Destroy()
	self.InventoryService:Destroy()
	self.PlayerService:Destroy()
end

return runtime
