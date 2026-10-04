local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local AttackLifecycle = require(script.AttackLifecycle)
local AttackInput = require(script.AttackInput)

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

local CombatController = {}
CombatController.__index = CombatController

-- True when `move_id` is the id of one of the weapon's combo moves.
local function is_combo_move_id(weapon, move_id)
	if not weapon or typeof(move_id) ~= "number" then
		return false
	end
	for _, name in ipairs(weapon.Combo) do
		local move = weapon.Moves[name]
		if move and move.Id == move_id then
			return true
		end
	end
	return false
end

function CombatController.new(deps)
	Deps.check(deps, "CombatController", { "weapon", "animation", "state", "input", "combat", "scheduler" })

	local self = setmetatable({
		Trove = Trove.new(),
		WeaponController = deps.weapon,
		AnimationController = deps.animation,
		State = deps.state,
		CombatClient = deps.combat,
		Scheduler = deps.scheduler,

		AttackTrove = nil,
		AttackLifecycleId = 0,
		AttackLease = nil,
		-- Reusable hitboxes by wielded part; the move each hitbox was last
		-- started for ({ Hitbox, MoveId, AttackTrove, LifecycleId }); and the
		-- currently started one.
		Hitboxes = {},
		HitboxOwners = {},
		ActiveHit = nil,

		-- The combo move the server expects next; nil means the first.
		NextComboMoveId = nil,
		PendingMoveId = nil,
		PendingAttackId = 0,
		CurrentMoveId = nil,
		CurrentMove = nil,
		CurrentTrack = nil,

		ChargeReady = false,

		-- Name of the hold move waiting for the cooldown.
		BufferedMove = nil,
		AttackReadyAt = 0,

		Charging = false,
		PrimaryHeld = false,
		PrimaryPressId = 0,
		PrimaryPressAttackPending = false,

		_destroyed = false,
	}, CombatController)

	local ok, err = pcall(self._start, self, deps.input)
	if not ok then
		self:Destroy()
		error(err, 0)
	end

	return self
end

function CombatController:_start(input_controller)
	self.Trove:Connect(
		self.CombatClient.AttackAccepted,
		function(move_id, next_combo_move_id)
			if move_id ~= self.PendingMoveId then
				return
			end

			self.PendingMoveId = nil
			if is_combo_move_id(self.WeaponController.Equipped, next_combo_move_id) then
				self.NextComboMoveId = next_combo_move_id
			end
		end
	)

	self.Trove:Connect(
		self.CombatClient.AttackRejected,
		function(move_id, next_combo_move_id)
			if self.PendingMoveId == move_id then
				self.PendingMoveId = nil
				if is_combo_move_id(self.WeaponController.Equipped, next_combo_move_id) then
					self.NextComboMoveId = next_combo_move_id
				end
			end
		end
	)

	self.Trove:Connect(
		input_controller.ActionBegan,
		function(action)
			if action == Actions.Primary then
				AttackInput.primary_began(self)
			end
		end
	)

	self.Trove:Connect(
		input_controller.ActionEnded,
		function(action)
			if action == Actions.Primary then
				AttackInput.primary_ended(self)
			end
		end
	)
end

function CombatController:_is_alive()
	local humanoid = self.WeaponController.Character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function has_cooldown(move)
	local cooldown = move.Cooldown
	return typeof(cooldown) == "number" and math.isfinite(cooldown) and cooldown > 0
end

-- The Primary tap: the next combo move, or the move Tap names directly.
-- Combo moves wait for the server's reply before the combo advances.
function CombatController:Attack()
	if self.PendingMoveId ~= nil or not self:_can_begin_attack() then
		return
	end

	if not self.State:CanStart("Attack") or not self:_is_alive() then
		return
	end

	local weapon = self.WeaponController.Equipped
	if not weapon then
		return
	end

	local tap = weapon.Bindings.Primary.Tap
	local is_combo = tap == Validator.ComboTap
	local move
	if is_combo then
		local move_id = self.NextComboMoveId or Catalog.ComboMoveId(weapon, 1)
		move = if is_combo_move_id(weapon, move_id) then Catalog.GetMove(weapon.Id, move_id) else nil
		if not move then
			self.NextComboMoveId = nil
			return
		end
	else
		move = weapon.Moves[tap]
	end

	if not move or not has_cooldown(move) then
		return
	end

	local track = self.AnimationController.Combat:BeginMove(move.Name)
	if not track then
		return
	end

	if is_combo then
		-- The server is authoritative over combo sequencing. Keep this request
		-- pending until AttackAccepted/AttackRejected arrives instead of
		-- advancing locally. The server always answers, but a lost or dropped
		-- reply must not block taps forever, so give up after
		-- PendingAttackTimeout. A late reply is then ignored and the next
		-- request resyncs the combo.
		self.PendingMoveId = move.Id
		self.PendingAttackId += 1
		local pending_attack_id = self.PendingAttackId
		self.Scheduler.after(Config.Combat.PendingAttackTimeout, function()
			if self.PendingAttackId == pending_attack_id then
				self.PendingMoveId = nil
			end
		end)
	end

	AttackLifecycle.begin_attack(self, move, track)
end

-- The Primary hold move (a Charge move).
function CombatController:Charge()
	if not self:_can_begin_attack() then
		return
	end

	if not self.State:CanStart("Charge") or not self:_is_alive() then
		return
	end

	local move = AttackInput.hold_move(self.WeaponController.Equipped)
	if not move or not has_cooldown(move) then
		return
	end

	local track = self.AnimationController.Combat:BeginMove(move.Name)
	if not track then
		return
	end

	AttackLifecycle.begin_attack(self, move, track)
end

function CombatController:_can_begin_attack()
	return self.Scheduler.clock() >= self.AttackReadyAt
end

function CombatController:_resolve_buffered_attack()
	AttackInput.resolve_buffered_attack(self)
end

function CombatController:_release_charge()
	AttackInput.release_charge(self)
end

function CombatController:_finish_attack(move_id, attack_trove)
	if self.AttackTrove ~= attack_trove then
		return
	end

	AttackLifecycle.stop_hitbox(self)
	self.CombatClient:Send(Protocol.Combat.HitStop, move_id)

	self.AttackTrove = nil
	self.Trove:Remove(attack_trove)

	self.Charging = false
	self.CurrentMoveId = nil
	self.CurrentMove = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	AttackLifecycle.release_lease(self)

	if self.BufferedMove then
		task.defer(function()
			if not self._destroyed then
				self:_resolve_buffered_attack()
			end
		end)
	end
end

function CombatController:Reset()
	self.AttackLifecycleId += 1
	self.PrimaryHeld = false
	self.PrimaryPressId += 1
	self.PrimaryPressAttackPending = false
	self.BufferedMove = nil

	AttackLifecycle.clear_attack_lifecycle(self)
	-- Hitboxes belong to the equipped weapon's parts; swaps and deaths reset here.
	AttackLifecycle.destroy_hitboxes(self)

	self.AnimationController:StopAction()
	AttackLifecycle.release_lease(self)

	-- Character death and weapon swaps reset through here, so a pending
	-- attack from the previous weapon or character never blocks new input.
	self.NextComboMoveId = nil
	self.PendingMoveId = nil
	self.PendingAttackId += 1
	self.AttackReadyAt = 0
	self.CurrentMoveId = nil
	self.CurrentMove = nil
	self.CurrentTrack = nil
	self.ChargeReady = false
	self.Charging = false
end

function CombatController:Destroy()
	if self._destroyed then
		return
	end
	self:Reset()
	self._destroyed = true
	self.Trove:Destroy()
end

return CombatController
