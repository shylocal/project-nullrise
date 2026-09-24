local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)
local CombatControllerModule = require(script.Parent.CombatController)

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character, input_controller, weapon_id)
	local trove = Trove.new()

	local weapon_controller = WeaponControllerModule.new(character)
	local movement_controller = MovementControllerModule.new(character, input_controller)
	local combat_controller = CombatControllerModule.new(
		weapon_controller,
		movement_controller,
		input_controller
	)

	local self = setmetatable({
		Character = character,
		Trove = trove,
		WeaponController = weapon_controller,
		MovementController = movement_controller,
		CombatController = combat_controller,
	}, CharacterController)

	trove:AttachToInstance(self.Character)
	trove:Add(weapon_controller)
	trove:Add(movement_controller)
	trove:Add(combat_controller)

	trove:Connect(
		movement_controller.SprintingChanged,
		function(sprinting)
			weapon_controller:SetSprinting(sprinting)
		end
	)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		trove:Connect(
			humanoid.Died,
			function()
				combat_controller:Reset()
			end
		)
	end

	weapon_controller:SetSprinting(movement_controller:IsSprinting())
	weapon_controller:EquipById(weapon_id or "Fists")

	return self
end

function CharacterController:SetWeapon(weapon_id)
	self.CombatController:Reset()
	return self.WeaponController:EquipById(weapon_id)
end

function CharacterController:IsAlive()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	return self.Character.Parent ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function CharacterController:Destroy()
	self.Trove:Destroy()
end

return CharacterController
