local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local ShapecastHitbox = require(Packages.ShapecastHitbox)

local Actions = require(ReplicatedStorage.shared.input.Actions)

local Remotes = ReplicatedStorage:WaitForChild("remotes")
local CombatRemote = Remotes:WaitForChild("Combat")

local CombatController = {}
CombatController.__index = CombatController

function CombatController.new(weapon_controller, input_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		WeaponController = weapon_controller,
		AttackTrove = nil,
		Hitbox = nil,
		NextAttack = 1,
		Attacking = false,

		Hit = Signal.new(),
	}, CombatController)

	self.Trove:Add(self.Hit)
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

	local attack_trove = Trove.new()
	self.AttackTrove = attack_trove
	self.Trove:Add(attack_trove)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStart"),
		function()
			self:_start_hitbox(attack_index)
			CombatRemote:FireServer("HitStart", attack_index)
		end
	)

	attack_trove:Connect(
		track:GetMarkerReachedSignal("HitStop"),
		function()
			self:_stop_hitbox()
			CombatRemote:FireServer("HitStop", attack_index)
		end
	)

	CombatRemote:FireServer("Attack", attack_index)

	task.spawn(function()
		track.Ended:Wait()

		self:_stop_hitbox()

		if self.AttackTrove == attack_trove then
			self.AttackTrove = nil
		end

		self.Trove:Remove(attack_trove)
		self.Attacking = false
	end)
end

function CombatController:_start_hitbox(attack_index)
	if self.Hitbox then
		return
	end

	local weapon = self.WeaponController.Equipped
	local attack = weapon and weapon.Attacks and weapon.Attacks[attack_index]
	if not attack then
		return
	end

	local wielded = self.WeaponController:GetWielded(attack.Hitbox)
	if not wielded then
		return
	end

	local raycast_params = RaycastParams.new()
	raycast_params.FilterType = Enum.RaycastFilterType.Exclude
	raycast_params.FilterDescendantsInstances = {self.WeaponController.Character}

	local hitbox = ShapecastHitbox.new(wielded, raycast_params)
	self.Hitbox = hitbox

	local hit_characters = {}

	hitbox:OnHit(function(raycast_result)
		local hit_part = raycast_result.Instance
		local hit_character = hit_part and hit_part:FindFirstAncestorOfClass("Model")
		if not hit_character or hit_character == self.WeaponController.Character then
			return
		end

		if hit_characters[hit_character] then
			return
		end

		hit_characters[hit_character] = true

		self.Hit:Fire(hit_character, raycast_result)
		CombatRemote:FireServer("Hit", attack_index, hit_character)
	end)

	self.AttackTrove:Add(hitbox)

	hitbox:HitStart()
end

function CombatController:_stop_hitbox()
	local hitbox = self.Hitbox
	self.Hitbox = nil

	if not hitbox then
		return
	end

	if hitbox.Active then
		hitbox:HitStop()
	end

	if self.AttackTrove then
		self.AttackTrove:Remove(hitbox)
	else
		hitbox:Destroy()
	end
end

function CombatController:Reset()
	self:_stop_hitbox()

	if self.AttackTrove then
		self.Trove:Remove(self.AttackTrove)
		self.AttackTrove = nil
	end

	self.NextAttack = 1
	self.Attacking = false
end

function CombatController:Destroy()
	self:_stop_hitbox()
	self.Trove:Destroy()
	self.AttackTrove = nil
end

return CombatController
