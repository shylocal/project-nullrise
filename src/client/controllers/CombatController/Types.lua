--!strict
-- Types shared by the CombatController modules. They live here rather than in
-- init so AttackLifecycle and AttackInput (which init requires) can name the
-- controller without a require cycle.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.packages.Signal)
local Trove = require(script.Parent.Parent.Parent.ClientTrove)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Scheduler = require(ReplicatedStorage.shared.runtime.Scheduler)

local CharacterState = require(script.Parent.Parent.CharacterState)
local WeaponController = require(script.Parent.Parent.WeaponController)
local Hitbox = require(script.Parent.Hitbox)

export type Signal = typeof(Signal.new())
export type Trove = Trove.Trove
export type Track = AnimationTrack
export type Move = Catalog.MoveDef

-- The AnimationController.Combat layer surface the controller uses. Method
-- `self` is `any` so the real layer and spec fakes both satisfy it.
export type CombatLayerLike = {
	BeginMove: (self: any, move_name: string) -> Track?,
	Play: (self: any, track: Track?, transition_time: number?) -> (),
	Pause: (self: any, track: Track) -> (),
	Resume: (self: any, track: Track) -> (),
}

-- The AnimationController (or a spec fake).
export type AnimationLike = {
	Combat: CombatLayerLike,
	-- Fires after the Animator was replaced and its tracks destroyed.
	CacheReset: Signal,
	StopAction: (self: any) -> (),
}

-- The session CombatClient surface the controller uses: AttackAccepted /
-- AttackRejected (move_id, next_combo_move_id) and Send.
export type CombatLike = {
	AttackAccepted: Signal,
	AttackRejected: Signal,
	Send: (self: any, action: string, ...any) -> (),
}

-- The InputController (or a spec fake): ActionBegan / ActionEnded (action).
export type InputLike = {
	ActionBegan: Signal,
	ActionEnded: Signal,
}

export type Deps = {
	weapon: WeaponController.WeaponController,
	animation: AnimationLike,
	state: CharacterState.CharacterState,
	input: InputLike,
	combat: CombatLike,
	scheduler: Scheduler.Scheduler,
}

-- The move a reusable hitbox was last started for.
export type HitOwner = {
	Hitbox: Hitbox.Hitbox,
	MoveId: number,
	AttackTrove: Trove,
	LifecycleId: number,
}

-- The controller as the combat modules see it. CombatController.new builds
-- it; its metatable supplies the methods listed at the end.
export type CombatController = {
	Trove: Trove,
	WeaponController: WeaponController.WeaponController,
	AnimationController: AnimationLike,
	State: CharacterState.CharacterState,
	CombatClient: CombatLike,
	Scheduler: Scheduler.Scheduler,

	AttackTrove: Trove?,
	AttackLifecycleId: number,
	AttackLease: CharacterState.Lease?,
	-- Reusable hitboxes by wielded part, the move each hitbox was last
	-- started for, and the currently started one.
	Hitboxes: { [Instance]: Hitbox.Hitbox },
	HitboxOwners: { [Hitbox.Hitbox]: HitOwner },
	ActiveHit: HitOwner?,

	-- The combo move the server expects next; nil means the first.
	NextComboMoveId: number?,
	PendingMoveId: number?,
	PendingAttackId: number,
	CurrentMoveId: number?,
	CurrentMove: Move?,
	CurrentTrack: Track?,

	ChargeReady: boolean,

	-- Name of the hold move waiting for the cooldown.
	BufferedMove: string?,
	AttackReadyAt: number,

	Charging: boolean,
	PrimaryHeld: boolean,
	PrimaryPressId: number,
	PrimaryPressAttackPending: boolean,

	_destroyed: boolean,

	Attack: (self: CombatController) -> (),
	Charge: (self: CombatController) -> (),
	Reset: (self: CombatController) -> (),
	Destroy: (self: CombatController) -> (),
	_start: (self: CombatController, input: InputLike) -> (),
	_is_alive: (self: CombatController) -> boolean,
	_can_begin_attack: (self: CombatController) -> boolean,
	_resolve_buffered_attack: (self: CombatController) -> (),
	_release_charge: (self: CombatController) -> (),
	_finish_attack: (self: CombatController, move_id: number, attack_trove: Trove) -> (),
}

return table.freeze({})
