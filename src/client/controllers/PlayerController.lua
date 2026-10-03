local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local CharacterControllerModule = require(script.Parent.CharacterController)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local InventoryRemote = ReplicatedStorage.remotes.Inventory
local WeaponRemote = ReplicatedStorage.remotes.Weapon

local FISTS_ID = "Fists"

-- Slot hotkeys only request a slot; the server validates it against its own
-- slot limit and answers with Inventory.Changed.
local SLOT_ACTIONS = {
	[Actions.Slot1] = 1,
	[Actions.Slot2] = 2,
}

local function is_valid_inventory(entries, selected_slot)
	if typeof(entries) ~= "table" then
		return false
	end
	if selected_slot ~= nil and typeof(selected_slot) ~= "number" then
		return false
	end

	for _, entry in ipairs(entries) do
		if typeof(entry) ~= "table"
			or typeof(entry.Slot) ~= "number"
			or typeof(entry.WeaponId) ~= "string" then
			return false
		end
	end

	return true
end

local PlayerController = {}
PlayerController.__index = PlayerController

-- ui_controller is optional so a UI startup failure cannot block gameplay.
function PlayerController.new(player, input_controller, ui_controller)
	local self = setmetatable({
		Player = player,
		Trove = Trove.new(),
		CharacterController = nil,
		PendingCharacter = nil,
		PendingTrove = nil,
		InputController = input_controller,
		UIController = ui_controller,
		CurrentWeaponId = FISTS_ID,
		InventoryEntries = {},
		SelectedSlot = nil,
		_destroyed = false,
	}, PlayerController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function PlayerController:_start()
	self.Trove:Connect(
		self.Player.CharacterAdded,
		function(character)
			self:_set_character(character)
		end
	)

	self.Trove:Connect(
		self.Player.CharacterRemoving,
		function(character)
			if self.PendingCharacter == character
				or (self.CharacterController and self.CharacterController.Character == character) then
				self:_clear_character()
			end
		end
	)

	-- Gameplay state is driven by the server's equipped-weapon event. The UI
	-- mirrors that state but never acts as the source of truth. This is the
	-- only client listener on these remotes so queued events are not split
	-- between handlers.
	self.Trove:Connect(
		WeaponRemote.OnClientEvent,
		function(action, weapon_id)
			if action ~= Protocol.Weapon.Equipped or typeof(weapon_id) ~= "string" then
				return
			end

			self.CurrentWeaponId = weapon_id
			self:_set_weapon(weapon_id)
			if self.UIController then
				self.UIController:SetEquipped(weapon_id)
			end
		end
	)

	self.Trove:Connect(
		InventoryRemote.OnClientEvent,
		function(action, entries, selected_slot)
			if action ~= Protocol.Inventory.Changed then
				return
			end
			if not is_valid_inventory(entries, selected_slot) then
				warn("PlayerController: ignoring malformed Inventory.Changed payload")
				return
			end

			self.InventoryEntries = entries
			self.SelectedSlot = selected_slot
			if self.UIController then
				self.UIController:SetInventory(entries, selected_slot)
			end
		end
	)

	self.Trove:Connect(
		self.InputController.ActionBegan,
		function(action)
			local slot = SLOT_ACTIONS[action]
			if slot then
				InventoryRemote:FireServer(Protocol.Inventory.SelectSlot, slot)
			end
		end
	)

	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player)
			if player == self.Player then
				self:Destroy()
			end
		end
	)

	local current_character = self.Player.Character
	if current_character then
		self:_set_character(current_character)
	end
end

function PlayerController:_set_character(character)
	if self._destroyed then
		return
	end

	local current = self.CharacterController

	if (current and current.Character == character) or self.PendingCharacter == character then
		return
	end

	self:_clear_character()

	if self.Player.Parent ~= Players then
		return
	end

	-- CharacterAdded can fire before the model is parented to Workspace.
	if not character:IsDescendantOf(Workspace) then
		self:_wait_for_workspace(character)
		return
	end

	self:_create_character_controller(character)
end

function PlayerController:_wait_for_workspace(character)
	local pending_trove = self.Trove:Extend()
	self.PendingCharacter = character
	self.PendingTrove = pending_trove

	pending_trove:Connect(
		character.AncestryChanged,
		function()
			if self.PendingCharacter ~= character or not character:IsDescendantOf(Workspace) then
				return
			end

			self:_clear_pending()
			self:_create_character_controller(character)
		end
	)

	pending_trove:Connect(
		character.Destroying,
		function()
			if self.PendingCharacter == character then
				self:_clear_pending()
			end
		end
	)
end

function PlayerController:_clear_pending()
	local pending_trove = self.PendingTrove
	self.PendingCharacter = nil
	self.PendingTrove = nil

	if pending_trove then
		self.Trove:Remove(pending_trove)
	end
end

function PlayerController:_create_character_controller(character)
	if self._destroyed or self.Player.Parent ~= Players then
		return
	end

	-- A rejected character (for example a non-R6 rig) is reported but must not
	-- take the rest of the client down with it.
	local ok, result = pcall(
		CharacterControllerModule.new,
		character,
		self.InputController,
		self.CurrentWeaponId
	)
	if not ok then
		warn(("PlayerController: character setup failed: %s"):format(tostring(result)))
		return
	end

	self.CharacterController = result
	self.Trove:Add(result)
	if self.UIController then
		self.UIController:BindCharacter(result)
	end
end

function PlayerController:_set_weapon(weapon_id)
	local controller = self.CharacterController
	if controller then
		controller:SetWeapon(weapon_id)
	end
end

function PlayerController:_clear_character()
	self:_clear_pending()

	if self.UIController then
		self.UIController:BindCharacter(nil)
	end

	local controller = self.CharacterController
	self.CharacterController = nil

	if controller then
		self.Trove:Remove(controller)
	end
end

function PlayerController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self.UIController then
		self.UIController:BindCharacter(nil)
	end
	self.Trove:Destroy()
	self.CharacterController = nil
	self.PendingCharacter = nil
	self.PendingTrove = nil
end

return PlayerController
