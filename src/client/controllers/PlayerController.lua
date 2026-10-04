--!strict
-- Owns the local player's CharacterController across respawns and maps slot
-- hotkeys to loadout requests. It does not listen to remotes: the session
-- clients (CombatClient, LoadoutClient) do.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Trove = require(script.Parent.Parent.ClientTrove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)
local CharacterController = require(script.Parent.CharacterController)
local InputController = require(script.Parent.InputController)
local CombatController = require(script.Parent.CombatController)
local LoadoutClient = require(script.Parent.Parent.session.LoadoutClient)

type Trove = Trove.Trove

-- The per-character controller as PlayerController sees it: CharacterController,
-- or a spec fake that records construction.
export type CharacterLike = CharacterController.CharacterController | {
	Character: Model,
	Destroy: (self: any) -> (),
}
export type CreateCharacter = (deps: CharacterController.Deps) -> CharacterLike

export type Deps = {
	player: Player,
	input: InputController.InputLike,
	-- The session CombatClient, forwarded to each CharacterController.
	combat: CombatController.CombatLike,
	loadout: LoadoutClient.LoadoutClient,
	scheduler: Scheduler.Scheduler,
	create_character: CreateCharacter,
}

type PlayerControllerFields = {
	Player: Player,
	Input: InputController.InputLike,
	Combat: CombatController.CombatLike,
	Loadout: LoadoutClient.LoadoutClient,
	Scheduler: Scheduler.Scheduler,
	CreateCharacter: CreateCharacter,
	Trove: Trove,
	CharacterController: CharacterLike?,
	-- A character waiting to be parented to Workspace, and the trove that
	-- watches it.
	PendingCharacter: Model?,
	PendingTrove: Trove?,
	_destroyed: boolean,
}

local PlayerController = {}
PlayerController.__index = PlayerController

export type PlayerController = typeof(setmetatable({} :: PlayerControllerFields, PlayerController))

-- deps.create_character builds the per-character controller from
-- { character, input, combat, loadout, scheduler } (CharacterController.new).
function PlayerController.new(deps: Deps): PlayerController
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
	} :: PlayerControllerFields, PlayerController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function PlayerController._start(self: PlayerController)
	self.Trove:Connect(
		self.Player.CharacterAdded,
		function(character: Model)
			self:_set_character(character)
		end
	)

	self.Trove:Connect(
		self.Player.CharacterRemoving,
		function(character: Model)
			local current = self.CharacterController
			if self.PendingCharacter == character or (current and current.Character == character) then
				self:_clear_character()
			end
		end
	)

	-- Slot hotkeys only request a slot; the server validates it against its own
	-- slot limit and answers with Inventory.Changed.
	self.Trove:Connect(
		self.Input.ActionBegan,
		function(action: string)
			local slot = Actions.slot_index(action)
			if slot then
				self.Loadout:SelectSlot(slot)
			end
		end
	)

	self.Trove:Connect(
		Players.PlayerRemoving,
		function(player: Player)
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

function PlayerController._set_character(self: PlayerController, character: Model)
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

function PlayerController._wait_for_workspace(self: PlayerController, character: Model)
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

function PlayerController._clear_pending(self: PlayerController)
	local pending_trove = self.PendingTrove
	self.PendingCharacter = nil
	self.PendingTrove = nil

	if pending_trove then
		self.Trove:Remove(pending_trove)
	end
end

function PlayerController._create_character_controller(self: PlayerController, character: Model)
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

function PlayerController._clear_character(self: PlayerController)
	self:_clear_pending()

	local controller = self.CharacterController
	self.CharacterController = nil

	if controller then
		self.Trove:Remove(controller)
	end
end

function PlayerController.Destroy(self: PlayerController)
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
