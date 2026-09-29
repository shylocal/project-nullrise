local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local AnimationControllerModule = require(script.Parent.AnimationController)
local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)
local ParkourControllerModule = require(script.Parent.ParkourController)
local CombatControllerModule = require(script.Parent.CombatController)

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(character, input_controller, weapon_id)
	local trove = Trove.new()
	local self = setmetatable({
		Character = character,
		Trove = trove,
		WeaponController = nil,
		AnimationController = nil,
		MovementController = nil,
		ParkourController = nil,
		CombatController = nil,
		_destroyed = false,
	}, CharacterController)

	-- Attach ownership before building dependent controllers so a failed
	-- initialization or character teardown cannot strand earlier resources.
	trove:AttachToInstance(character)

	local ok, err = pcall(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		self.WeaponController = WeaponControllerModule.new(character)
		self.AnimationController = AnimationControllerModule.new(character)
		trove:Add(self.AnimationController)

		self.MovementController = MovementControllerModule.new(character, input_controller)
		trove:Add(self.MovementController)

		self.ParkourController = ParkourControllerModule.new(
			character,
			input_controller,
			self.MovementController
		)
		trove:Add(self.ParkourController)

		self.CombatController = CombatControllerModule.new(
			self.WeaponController,
			self.AnimationController,
			self.MovementController,
			input_controller
		)
		trove:Add(self.CombatController)

		trove:Connect(self.MovementController.SprintingChanged, function(sprinting)
			self.AnimationController:SetSprinting(sprinting)
		end)

		if humanoid then
			trove:Connect(humanoid.Died, function()
				self.CombatController:Reset()
			end)
		end

		local equipped = self.WeaponController:EquipById(weapon_id or "Fists")
		if not equipped then
			self.WeaponController:EquipById("Fists")
		end
		self.AnimationController:SetWeapon(self.WeaponController.Equipped)
		self.AnimationController:SetSprinting(self.MovementController:IsSprinting())
	end)

	if not ok then
		trove:Destroy()
		error(err, 0)
	end

	return self
end

function CharacterController:SetWeapon(weapon_id)
	self.CombatController:Reset()
	if not self.WeaponController:EquipById(weapon_id) then
		return false
	end
	self.AnimationController:SetWeapon(self.WeaponController.Equipped)
	return true
end

function CharacterController:IsAlive()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	return self.Character.Parent ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function CharacterController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
end

return CharacterController
