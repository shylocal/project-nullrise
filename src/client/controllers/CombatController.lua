local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local Actions = require(ReplicatedStorage.shared.input.Actions)

local Remotes = ReplicatedStorage:WaitForChild("remotes")
local CombatRemote = Remotes:WaitForChild("Combat")

local CombatController = {}
CombatController.__index = CombatController

function CombatController.new(weapon_controller, input_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		WeaponController = weapon_controller,
		NextAttack = 1,
		Attacking = false,
	}, CombatController)

	self:_start(input_controller)

	return self
end

function CombatController:_start(input_controller)
	self.Trove:Connect(
		input_controller.ActionBegan,
		function(action)
			if action == Actions.Primary then
				self:Attack()
			end
		end
	)
end

function CombatController:Attack()
	if self.Attacking then
		return
	end

	local weapon = self.WeaponController.Equipped
	if not weapon or not weapon.Attacks then
		return
	end

	local attack_index = self.NextAttack
	local attack = weapon.Attacks[attack_index]
	if not attack then
		return
	end

	local track = self.WeaponController:Attack(attack_index)
	if not track then
		return
	end

	self.Attacking = true
	self.NextAttack = attack_index == #weapon.Attacks and 1 or attack_index + 1

	CombatRemote:FireServer(attack_index)

	task.spawn(function()
		track.Ended:Wait()
		self.Attacking = false
	end)
end

function CombatController:Reset()
	self.NextAttack = 1
	self.Attacking = false
end

function CombatController:Destroy()
	self.Trove:Destroy()
end

return CombatController
