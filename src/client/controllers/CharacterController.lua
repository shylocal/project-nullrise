--!strict
-- Builds and owns every per-character controller. Children are composed with a
-- Runtime so they are torn down in reverse construction order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(script.Parent.Parent.ClientTrove)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local CharacterStateModule = require(script.Parent.CharacterState)
local CharacterStatePolicy = require(script.Parent.CharacterState.Policy)
local AnimationControllerModule = require(script.Parent.AnimationController)
local WeaponControllerModule = require(script.Parent.WeaponController)
local MovementControllerModule = require(script.Parent.MovementController)
local ParkourControllerModule = require(script.Parent.ParkourController)
local CombatControllerModule = require(script.Parent.CombatController)
local InputController = require(script.Parent.InputController)

local LoadoutClient = require(script.Parent.Parent.session.LoadoutClient)

type Trove = Trove.Trove

export type Deps = {
	character: Model,
	input: InputController.InputLike,
	-- The session CombatClient, forwarded to the CombatController.
	combat: CombatControllerModule.CombatLike,
	loadout: LoadoutClient.LoadoutClient,
	scheduler: Scheduler.Scheduler,
}

-- The child controllers are nil until the Runtime has started them in new.
type CharacterControllerFields = {
	Character: Model,
	Loadout: LoadoutClient.LoadoutClient,
	Trove: Trove,
	Runtime: Runtime.Runtime,
	CharacterState: CharacterStateModule.CharacterState?,
	WeaponController: WeaponControllerModule.WeaponController?,
	AnimationController: AnimationControllerModule.AnimationController?,
	MovementController: MovementControllerModule.MovementController?,
	ParkourController: ParkourControllerModule.Controller?,
	CombatController: CombatControllerModule.CombatController?,
	_destroyed: boolean,
	_watched_humanoids: { [Humanoid]: boolean },
}

local R6_ERROR = "project-nullrise requires R6 character rigs"

local CharacterController = {}
CharacterController.__index = CharacterController

export type CharacterController = typeof(setmetatable({} :: CharacterControllerFields, CharacterController))

function CharacterController.new(deps: Deps): CharacterController
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
	} :: CharacterControllerFields, CharacterController)

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
		trove:Connect(character.ChildAdded, function(child: Instance)
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
		local animation_controller: AnimationControllerModule.AnimationController = runtime:Get("AnimationController")
		local movement_controller: MovementControllerModule.MovementController = runtime:Get("MovementController")
		self.WeaponController = runtime:Get("WeaponController")
		self.AnimationController = animation_controller
		self.MovementController = movement_controller
		self.ParkourController = runtime:Get("ParkourController")
		self.CombatController = runtime:Get("CombatController")

		trove:Connect(movement_controller.SprintingChanged, function(sprinting: boolean)
			animation_controller:SetSprinting(sprinting)
		end)

		trove:Connect(deps.loadout.EquippedChanged, function(weapon_id: string)
			self:SetWeapon(weapon_id)
		end)

		if not self:SetWeapon(deps.loadout.EquippedId) then
			self:SetWeapon(Catalog.DefaultId)
		end
		animation_controller:SetSprinting(movement_controller:IsSprinting())
	end)

	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CharacterController._watch_humanoid(self: CharacterController, humanoid: Humanoid)
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

function CharacterController.SetWeapon(self: CharacterController, weapon_id: string): boolean
	if self._destroyed then
		return false
	end

	local combat_controller = self.CombatController
	local weapon_controller = self.WeaponController
	local animation_controller = self.AnimationController
	assert(
		combat_controller and weapon_controller and animation_controller,
		"CharacterController:SetWeapon called before the controllers started"
	)

	combat_controller:Reset()
	if not weapon_controller:EquipById(weapon_id) then
		return false
	end
	animation_controller:SetWeapon(weapon_controller.Equipped)
	return true
end

function CharacterController.Destroy(self: CharacterController)
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
