-- Owns the local player's CharacterController across respawns and maps slot
-- hotkeys to loadout requests. It does not listen to remotes: the session
-- clients (CombatClient, LoadoutClient) do.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local PlayerController = {}
PlayerController.__index = PlayerController

-- deps.create_character builds the per-character controller from
-- { character, input, combat, loadout, scheduler } (CharacterController.new).
function PlayerController.new(deps)
	Deps.check(deps, "PlayerController", { "player", "input", "combat", "loadout", "scheduler", "create_character" })

	local self = setmetatable({
		Player = deps.player,
		Input = deps.input,
		Combat = deps.combat,
		Loadout = deps.loadout,
		Scheduler = deps.scheduler,
		CreateCharacter = deps.create_character,
		Trove = Trove.new(),
		CharacterController = nil,
		PendingCharacter = nil,
		PendingTrove = nil,
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

	-- Slot hotkeys only request a slot; the server validates it against its own
	-- slot limit and answers with Inventory.Changed.
	self.Trove:Connect(
		self.Input.ActionBegan,
		function(action)
			local slot = Actions.slot_index(action)
			if slot then
				self.Loadout:SelectSlot(slot)
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
	local ok, result = pcall(self.CreateCharacter, {
		character = character,
		input = self.Input,
		combat = self.Combat,
		loadout = self.Loadout,
		scheduler = self.Scheduler,
	})
	if not ok then
		warn(("PlayerController: character setup failed: %s"):format(tostring(result)))
		return
	end

	self.CharacterController = result
	self.Trove:Add(result)
end

function PlayerController:_clear_character()
	self:_clear_pending()

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
	self.Trove:Destroy()
	self.CharacterController = nil
	self.PendingCharacter = nil
	self.PendingTrove = nil
end

return PlayerController
