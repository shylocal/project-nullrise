--!strict
-- The parkour state machine. A state is one tagged record, so per-state data
-- cannot outlive its state. Each state also owns resources: its CharacterState
-- lease and its Humanoid override handles. Entering a state acquires them and
-- leaving it releases them, except what is handed over to the next state
-- (Hang -> Mantle keeps the Hang body pose until the mantle ends; a
-- same-kind transition keeps everything).
local CharacterStateModule = require(script.Parent.Parent.CharacterState)
local Types = require(script.Parent.Types)

type Controller = Types.Controller
export type HangData = Types.HangData
export type MantleData = Types.MantleData
export type VaultData = Types.VaultData
export type TopHopData = Types.TopHopData
export type ParkourState = Types.ParkourState
export type Resources = Types.Resources

local State = {}

local TRANSITIONS: { [string]: { [string]: boolean } } = {
	Grounded = { Grounded = true, Hanging = true, Vaulting = true },
	Hanging = { Hanging = true, Grounded = true, Mantling = true },
	Mantling = { Mantling = true, Grounded = true, Hanging = true },
	Vaulting = { Vaulting = true, Grounded = true },
}

local function overrides_of(ctrl: Controller): (CharacterStateModule.HumanoidOverrides?, Humanoid?)
	local humanoid = ctrl.Humanoid
	if not humanoid then
		return nil, nil
	end
	return ctrl.CharacterState:Overrides(humanoid), humanoid
end

local function release(resources: Resources)
	local connection = resources.Connection
	if connection then
		resources.Connection = nil
		connection:Disconnect()
	end
	local jump = resources.Jump
	if jump then
		resources.Jump = nil
		jump:Pop()
	end
	local body = resources.Body
	if body then
		resources.Body = nil
		body:Pop()
	end
	local lease = resources.Lease
	if lease then
		resources.Lease = nil
		lease:Release()
	end
end

-- Which of the outgoing state's resources the incoming state keeps.
type Handover = { Lease: boolean, Body: boolean, Jump: boolean, Connection: boolean }

local KEEP_ALL: Handover = table.freeze({ Lease = true, Body = true, Jump = true, Connection = true })
local KEEP_BODY: Handover = table.freeze({ Lease = false, Body = true, Jump = false, Connection = false })
local KEEP_NONE: Handover = table.freeze({ Lease = false, Body = false, Jump = false, Connection = false })

local function top_hop_of(state: ParkourState): TopHopData?
	if state.kind == "Grounded" then
		return state.TopHop
	end
	return nil
end

local function handover(current: ParkourState, next_state: ParkourState): Handover
	if current.kind == next_state.kind then
		if current.kind ~= "Grounded" then
			return KEEP_ALL
		end
		-- A grounded top-hop keeps its resources only while it is the same record.
		local current_hop = top_hop_of(current)
		if current_hop ~= nil and current_hop == top_hop_of(next_state) then
			return KEEP_ALL
		end
		return KEEP_NONE
	end
	if (current.kind == "Hanging" and next_state.kind == "Mantling")
		or (current.kind == "Mantling" and next_state.kind == "Hanging") then
		return KEEP_BODY
	end
	return KEEP_NONE
end

local function enter_grounded(ctrl: Controller, next_state: ParkourState, kept: Resources): Resources
	if top_hop_of(next_state) == nil or kept.Lease ~= nil then
		return kept
	end
	kept.Lease = ctrl.CharacterState:Acquire(ctrl, "TopHop")
	local overrides, humanoid = overrides_of(ctrl)
	if overrides and humanoid then
		-- The native jump impulse overshoots the computed launch velocity, so
		-- it is zeroed only for the launch's Jumping state; the Jumping
		-- transition and animation still play.
		kept.Jump = if humanoid.UseJumpPower
			then overrides:Push("TopHop", { JumpPower = 0 })
			else overrides:Push("TopHop", { JumpHeight = 0 })
		kept.Connection = humanoid.StateChanged:Connect(function(old_state, new_state)
			if old_state == Enum.HumanoidStateType.Jumping and new_state ~= Enum.HumanoidStateType.Jumping then
				State.restore_top_hop_jump(ctrl)
			end
		end)
	end
	return kept
end

local function enter_hanging(ctrl: Controller, _next_state: ParkourState, kept: Resources): Resources
	if not kept.Lease then
		kept.Lease = ctrl.CharacterState:Acquire(ctrl, "Hang")
	end
	if not kept.Body then
		local overrides = overrides_of(ctrl)
		if overrides then
			kept.Body = overrides:Push("Hang", { AutoRotate = false, PlatformStand = true })
		end
	end
	return kept
end

local function enter_mantling(ctrl: Controller, _next_state: ParkourState, kept: Resources): Resources
	if kept.Lease then
		return kept
	end
	kept.Lease = ctrl.CharacterState:Acquire(ctrl, "Mantle")
	local overrides, humanoid = overrides_of(ctrl)
	if overrides and humanoid then
		if not kept.Body then
			kept.Body = overrides:Push("Hang", { AutoRotate = false, PlatformStand = true })
		end
		-- Native jumping stays disabled until Space is released, even after
		-- the mantle completes: the Jump latch owns this handle.
		ctrl.Latch:Block("Jump", { overrides:Push("Mantle", { JumpingEnabled = false }) })
		humanoid.Jump = false
	else
		ctrl.Latch:Block("Jump")
	end
	return kept
end

local function enter_vaulting(ctrl: Controller, _next_state: ParkourState, kept: Resources): Resources
	if kept.Lease then
		return kept
	end
	kept.Lease = ctrl.CharacterState:Acquire(ctrl, "Vault")
	local overrides, humanoid = overrides_of(ctrl)
	if overrides and humanoid then
		kept.Body = overrides:Push("Vault", {
			AutoRotate = false,
			PlatformStand = true,
			HipHeight = humanoid.HipHeight,
		})
		humanoid.Jump = false
		kept.Jump = overrides:Push("Vault", { JumpingEnabled = false })
	end
	return kept
end

local ENTER: { [string]: (Controller, ParkourState, Resources) -> Resources } = {
	Grounded = enter_grounded,
	Hanging = enter_hanging,
	Mantling = enter_mantling,
	Vaulting = enter_vaulting,
}

-- Puts a controller in the initial Grounded state.
function State.init(ctrl: Controller)
	ctrl._state = { kind = "Grounded" } :: ParkourState
	ctrl._resources = {} :: Resources
end

-- Transitions to `next_state` if TRANSITIONS allows it. The incoming state's
-- resources are acquired before the outgoing state's are released, so a lease
-- hand-off (Hang -> Mantle) never briefly unblocks an action.
function State.enter(ctrl: Controller, next_state: ParkourState): boolean
	local current: ParkourState = ctrl._state
	local allowed = TRANSITIONS[current.kind]
	if not allowed or not allowed[next_state.kind] then
		return false
	end

	local outgoing: Resources = ctrl._resources
	local kept: Resources = {}
	local keep = handover(current, next_state)
	if keep.Lease then
		kept.Lease, outgoing.Lease = outgoing.Lease, nil
	end
	if keep.Body then
		kept.Body, outgoing.Body = outgoing.Body, nil
	end
	if keep.Jump then
		kept.Jump, outgoing.Jump = outgoing.Jump, nil
	end
	if keep.Connection then
		kept.Connection, outgoing.Connection = outgoing.Connection, nil
	end

	local incoming = ENTER[next_state.kind](ctrl, next_state, kept)
	ctrl._state = next_state
	ctrl._resources = incoming
	release(outgoing)

	if current.kind == "Hanging" and next_state.kind ~= "Hanging" then
		ctrl.CornerProbeMiss = nil
	end
	return true
end

-- Releases every resource of the current state and returns to Grounded
-- without a TopHop. Used by Destroy.
function State.reset(ctrl: Controller)
	local outgoing: Resources = ctrl._resources
	ctrl._state = { kind = "Grounded" } :: ParkourState
	ctrl._resources = {} :: Resources
	release(outgoing)
	ctrl.CornerProbeMiss = nil
end

function State.kind(ctrl: Controller): string
	return ctrl._state.kind
end

function State.hang(ctrl: Controller): HangData?
	local state: ParkourState = ctrl._state
	if state.kind == "Hanging" then
		return state.data
	end
	return nil
end

function State.mantle(ctrl: Controller): MantleData?
	local state: ParkourState = ctrl._state
	if state.kind == "Mantling" then
		return state.data
	end
	return nil
end

function State.vault(ctrl: Controller): VaultData?
	local state: ParkourState = ctrl._state
	if state.kind == "Vaulting" then
		return state.data
	end
	return nil
end

function State.top_hop(ctrl: Controller): TopHopData?
	local state: ParkourState = ctrl._state
	if state.kind == "Grounded" then
		return state.TopHop
	end
	return nil
end

-- The current state's resources (read by traversal code that adjusts its
-- own override handles, e.g. the vault crouch).
function State.resources(ctrl: Controller): Resources
	return ctrl._resources
end

-- Restores the native jump setting zeroed for a top-hop launch. The TopHop
-- record and lease stay until landing so they keep guarding against re-vaults.
function State.restore_top_hop_jump(ctrl: Controller)
	if State.top_hop(ctrl) == nil then
		return
	end
	local resources: Resources = ctrl._resources
	local connection = resources.Connection
	if connection then
		resources.Connection = nil
		connection:Disconnect()
	end
	local jump = resources.Jump
	if jump then
		resources.Jump = nil
		jump:Pop()
	end
end

return State
