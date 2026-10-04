-- Builds and owns every per-character controller. Children are composed with a
-- Runtime so they are torn down in reverse construction order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)

local CharacterStateModule = require(script.Parent.CharacterState)
local CharacterStatePolicy = require(script.Parent.CharacterState.Policy)
local AnimationControllerModule = require(script.Parent.AnimationController)
local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)
local ParkourControllerModule = require(script.Parent.ParkourController)
local CombatControllerModule = require(script.Parent.CombatController)

local R6_ERROR = "project-nullrise requires R6 character rigs"

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new(deps)
	Deps.check(deps, "CharacterController", { "character", "input", "combat", "loadout", "scheduler" })

	local character = deps.character
	local input = deps.input
	local trove = Trove.new()
	local runtime = Runtime.new("Character")

	local self = setmetatable({
		Character = character,
		Loadout = deps.loadout,
		Trove = trove,
		Runtime = runtime,
		CharacterState = nil,
		WeaponController = nil,
		AnimationController = nil,
		MovementController = nil,
		ParkourController = nil,
		CombatController = nil,
		_destroyed = false,
		_watched_humanoids = {},
	}, CharacterController)

	-- Character teardown destroys everything. Destroying is used instead of
	-- Trove:AttachToInstance, which errors for an unparented character.
	trove:Connect(character.Destroying, function()
		self:Destroy()
	end)

	local ok, err = pcall(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.RigType ~= Enum.HumanoidRigType.R6 then
			error(R6_ERROR)
		end
		if humanoid then
			self:_watch_humanoid(humanoid)
		end
		trove:Connect(character.ChildAdded, function(child)
			if child:IsA("Humanoid") then
				if child.RigType ~= Enum.HumanoidRigType.R6 then
					error(R6_ERROR)
				end
				self:_watch_humanoid(child)
			end
		end)

		runtime:Add("CharacterState", function()
			return CharacterStateModule.new({ policy = CharacterStatePolicy })
		end)
		runtime:Add("WeaponController", function()
			return WeaponControllerModule.new({ character = character })
		end)
		runtime:Add("AnimationController", function()
			return AnimationControllerModule.new({ character = character })
		end)
		runtime:Add("MovementController", function(get)
			return MovementControllerModule.new({
				character = character,
				input = input,
				state = get("CharacterState"),
			})
		end)
		runtime:Add("ParkourController", function(get)
			return ParkourControllerModule.new({
				character = character,
				input = input,
				movement = get("MovementController"),
				state = get("CharacterState"),
			})
		end)
		runtime:Add("CombatController", function(get)
			return CombatControllerModule.new({
				weapon = get("WeaponController"),
				animation = get("AnimationController"),
				state = get("CharacterState"),
				input = input,
				combat = deps.combat,
				scheduler = deps.scheduler,
			})
		end)
		runtime:Start()

		self.CharacterState = runtime:Get("CharacterState")
		self.WeaponController = runtime:Get("WeaponController")
		self.AnimationController = runtime:Get("AnimationController")
		self.MovementController = runtime:Get("MovementController")
		self.ParkourController = runtime:Get("ParkourController")
		self.CombatController = runtime:Get("CombatController")

		trove:Connect(self.MovementController.SprintingChanged, function(sprinting)
			self.AnimationController:SetSprinting(sprinting)
		end)

		trove:Connect(deps.loadout.EquippedChanged, function(weapon_id)
			self:SetWeapon(weapon_id)
		end)

		if not self:SetWeapon(deps.loadout.EquippedId) then
			self:SetWeapon(Catalog.DefaultId)
		end
		self.AnimationController:SetSprinting(self.MovementController:IsSprinting())
	end)

	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CharacterController:_watch_humanoid(humanoid)
	if self._watched_humanoids[humanoid] then
		return
	end
	self._watched_humanoids[humanoid] = true

	self.Trove:Connect(humanoid.Died, function()
		if self.CombatController then
			self.CombatController:Reset()
		end
	end)
end

function CharacterController:SetWeapon(weapon_id)
	if self._destroyed then
		return false
	end

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

	-- Disconnect character and loadout events before tearing children down.
	self.Trove:Destroy()
	self.Runtime:Destroy()
	table.clear(self._watched_humanoids)
end

return CharacterController
