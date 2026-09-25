local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local AnimationControllerModule = require(script.Parent.AnimationController)
local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)
local CombatControllerModule = require(script.Parent.CombatController)

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character, input_controller, weapon_id)
	local trove = Trove.new()

	local weapon_controller = WeaponControllerModule.new(character)
	local animation_controller = AnimationControllerModule.new(character)
	local movement_controller = MovementControllerModule.new(character, input_controller)
	local combat_controller = CombatControllerModule.new(
		weapon_controller,
		animation_controller,
		movement_controller,
		input_controller
	)

	local self = setmetatable({
		Character = character,
		Trove = trove,
		WeaponController = weapon_controller,
		AnimationController = animation_controller,
		MovementController = movement_controller,
		CombatController = combat_controller,
	}, CharacterController)

	trove:AttachToInstance(self.Character)
	trove:Add(weapon_controller)
	trove:Add(animation_controller)
	trove:Add(movement_controller)
	trove:Add(combat_controller)

	trove:Connect(
		movement_controller.SprintingChanged,
		function(sprinting)
			animation_controller:SetSprinting(sprinting)
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

	local equipped = weapon_controller:EquipById(weapon_id or "Fists")
	if not equipped then
		weapon_controller:EquipById("Fists")
	end

	animation_controller:SetWeapon(weapon_controller.Equipped)
	animation_controller:SetSprinting(movement_controller:IsSprinting())

	task.defer(function()
		if self.Trove then
			animation_controller:PlayEquip()
		end
	end)

	return self
end

function CharacterController:SetWeapon(weapon_id)
	self.CombatController:Reset()

	if not self.WeaponController:EquipById(weapon_id) then
		return false
	end

	self.AnimationController:SetWeapon(self.WeaponController.Equipped)
	self.AnimationController:PlayEquip()

	return true
end

function CharacterController:IsAlive()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	return self.Character.Parent ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function CharacterController:Destroy()
	self.Trove:Destroy()
end

return CharacterController
