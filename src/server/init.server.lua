local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerService = require(script.services.PlayerService)
local WeaponService = require(script.services.WeaponService)
local CombatService = require(script.services.CombatService)

local remotes = ReplicatedStorage:FindFirstChild("remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "remotes"
	remotes.Parent = ReplicatedStorage
end

local combat_remote = remotes:FindFirstChild("Combat")
if not combat_remote then
	combat_remote = Instance.new("RemoteEvent")
	combat_remote.Name = "Combat"
	combat_remote.Parent = remotes
end

local player_service = PlayerService.new()
local weapon_service = WeaponService.new(player_service)
local combat_service = CombatService.new(player_service, weapon_service, combat_remote)

return {
	PlayerService = player_service,
	WeaponService = weapon_service,
	CombatService = combat_service,
}
