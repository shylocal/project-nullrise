--!strict
-- Types shared by the ParkourController modules. They live here rather than in
-- init so the traversal modules (which init requires) can name the controller
-- without a require cycle. State re-exports the state records.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.packages.Signal)

local ClientTrove = require(script.Parent.Parent.Parent.ClientTrove)
local CharacterStateModule = require(script.Parent.Parent.CharacterState)
local ClimbableIndex = require(script.Parent.ClimbableIndex)
local InputLatch = require(script.Parent.InputLatch)
local Metrics = require(script.Parent.Metrics)
local QueryContext = require(script.Parent.QueryContext)

export type Signal = typeof(Signal.new())
export type Trove = ClientTrove.Trove

-- The input dependency (InputController or a spec fake). Method `self` is
-- `any` so both metatable classes and plain fakes satisfy the shape.
export type InputLike = {
	ActionBegan: Signal,
	ActionEnded: Signal,
	IsDown: (self: any, action: string) -> boolean,
}

-- The movement dependency (MovementController or a spec fake).
export type MovementLike = {
	IsSprinting: (self: any) -> boolean,
}

export type HangData = {
	CurrentClimbable: Instance,
	Normal: Vector3,
	HangDepthOffset: Vector3,
	HangPosition: Vector3,
	CornerLockPosition: Vector3?,
	CornerLockInputDirection: number?,
}
export type MantleData = { Start: CFrame, Target: CFrame, Elapsed: number, Duration: number }
export type VaultData = {
	ExitVelocity: Vector3,
	Start: CFrame,
	Target: CFrame,
	Elapsed: number,
	Duration: number,
	ArcHeight: number,
	ArcPeakProgress: number,
	Obstacle: BasePart,
}
export type TopHopData = { StartedAt: number, SawAir: boolean }
export type ParkourState =
	{ kind: "Grounded", TopHop: TopHopData? }
	| { kind: "Hanging", data: HangData }
	| { kind: "Mantling", data: MantleData }
	| { kind: "Vaulting", data: VaultData }

-- Body: pose overrides (AutoRotate/PlatformStand[/HipHeight]).
-- Jump: the disabled-jump (Vault) or zeroed jump impulse (TopHop) override.
export type Resources = {
	Lease: CharacterStateModule.Lease?,
	Body: CharacterStateModule.Handle?,
	Jump: CharacterStateModule.Handle?,
	Connection: RBXScriptConnection?,
}

-- A walkable top surface of a climb guide (Queries.get_guide_top).
export type GuideTop = {
	Instance: BasePart,
	Guide: Instance,
	Position: Vector3,
	Normal: Vector3,
	BoxCFrame: CFrame,
	BoxSize: Vector3,
}

-- The last empty corner-fan search (see Traversal.can_reuse_corner_miss).
export type CornerProbeMiss = {
	Climbable: Instance,
	Direction: number,
	Normal: Vector3,
	HangPosition: Vector3,
	RootPosition: Vector3,
	At: number,
}

-- The controller as the parkour modules see it. ParkourController.new builds
-- it; its metatable supplies the methods listed at the end.
export type Controller = {
	Character: Model,
	Input: InputLike,
	Movement: MovementLike,
	CharacterState: CharacterStateModule.CharacterState,
	Trove: Trove,
	Humanoid: Humanoid?,
	Root: BasePart?,
	Latch: InputLatch.InputLatch,
	Climbables: ClimbableIndex.ClimbableIndex,
	Metrics: Metrics.State,
	Query: QueryContext.QueryContext,
	CornerProbeMiss: CornerProbeMiss?,
	HangClearanceProbe: BasePart?,
	NextVaultAt: number,
	_state: ParkourState,
	_resources: Resources,
	_destroyed: boolean,

	GetQueryMetrics: (self: Controller) -> { [string]: number },
	ResetQueryMetrics: (self: Controller) -> (),
	Destroy: (self: Controller) -> (),
	_start: (self: Controller) -> (),
	_bind_character_parts: (self: Controller) -> (),
	_bind_humanoid: (self: Controller, humanoid: Humanoid) -> (),
	_grab: (self: Controller, guide: Instance, normal: Vector3, position: Vector3, edge_gap: number, dt: number) -> (),
	_step: (self: Controller, dt: number) -> (),
	_standing_height: (self: Controller) -> number,
	_position_hanging: (self: Controller, dt: number) -> (),
	_release: (self: Controller) -> (),
}

return table.freeze({})
