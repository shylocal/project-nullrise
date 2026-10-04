-- Ledge grabbing, hanging traversal, mantling and vaulting for the local
-- character. State transitions live in State (which owns the leases and
-- Humanoid overrides of each state); spatial queries live in Queries,
-- LedgeDetection and the traversal modules.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)
local SharedConfig = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local ClimbableIndex = require(script.ClimbableIndex)
local InputLatch = require(script.InputLatch)
local LedgeTraversal = require(script.LedgeTraversal)
local Metrics = require(script.Metrics)
local Queries = require(script.Queries)
local QueryContext = require(script.QueryContext)
local State = require(script.State)
local Traversal = require(script.Traversal)
local VaultTraversal = require(script.VaultTraversal)

local Config = SharedConfig.Parkour
local ROOT_PART = SharedConfig.World.Names.RootPart
local METRICS_ATTRIBUTE = SharedConfig.World.Attributes.ParkourQueryMetrics

local ParkourController = {}
ParkourController.__index = ParkourController

-- deps.character: Model; deps.input: InputController-like (ActionBegan,
-- ActionEnded, IsDown); deps.movement: MovementController (IsSprinting);
-- deps.state: CharacterState.
function ParkourController.new(deps)
	Deps.check(deps, "ParkourController", { "character", "input", "movement", "state" })
	local character = deps.character
	local self = setmetatable({
		Character = character,
		Input = deps.input,
		Movement = deps.movement,
		CharacterState = deps.state,
		Trove = Trove.new(),
		Humanoid = nil,
		Root = character:FindFirstChild(ROOT_PART),
		Latch = InputLatch.new(),
		Climbables = ClimbableIndex.get(),
		Metrics = Metrics.new(character:GetAttribute(METRICS_ATTRIBUTE) == true),
		Query = nil,
		CornerProbeMiss = nil,
		HangClearanceProbe = nil,
		NextVaultAt = 0,
		_destroyed = false,
	}, ParkourController)
	State.init(self)
	self.Query = QueryContext.new(self)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function ParkourController:_start()
	self.Trove:Connect(self.Character:GetAttributeChangedSignal(METRICS_ATTRIBUTE), function()
		Metrics.set_enabled(self, self.Character:GetAttribute(METRICS_ATTRIBUTE) == true)
	end)

	self.Trove:Connect(self.Input.ActionBegan, function(action)
		local kind = State.kind(self)
		if action == Actions.Jump then
			if kind == "Grounded" then
				-- Space explicitly requests a vault; if no valid vault is found,
				-- the ordinary jump or ledge-grab flow remains available.
				VaultTraversal.try_vault(self)
			end
		elseif action == Actions.Forward and kind == "Hanging" then
			if not self.Latch:IsBlocked("Forward") then
				LedgeTraversal.try_mantle(self)
			end
		elseif action == Actions.Backward and kind == "Hanging" then
			LedgeTraversal.try_lower_ledge(self)
		end
	end)

	self.Trove:Connect(self.Input.ActionEnded, function(action)
		if action == Actions.Forward then
			self.Latch:Release("Forward")
		end
		if action == Actions.Jump then
			self.Latch:Release("Jump")
			if State.kind(self) == "Hanging" then
				-- Releasing Space simply lets go; normal gravity handles the drop.
				self:_release()
			end
		end
	end)

	self.Trove:Connect(RunService.Heartbeat, function(dt)
		self:_step(dt)
	end)

	self:_bind_character_parts()
	self.Trove:Connect(self.Character.ChildAdded, function(child)
		if child.Name == ROOT_PART then
			self.Root = child
		elseif child:IsA("Humanoid") then
			self:_bind_humanoid(child)
		end
	end)
end

function ParkourController:_bind_character_parts()
	self.Root = self.Character:FindFirstChild(ROOT_PART)
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self:_bind_humanoid(humanoid)
	end
end

function ParkourController:_bind_humanoid(humanoid)
	if self.Humanoid == humanoid then return end
	self.Humanoid = humanoid
	self.Trove:Connect(humanoid.Died, function()
		self:_release()
	end)
end

function ParkourController:_grab(guide, normal, position, edge_gap, dt)
	local humanoid = self.Humanoid
	if State.kind(self) ~= "Grounded" or not guide or not humanoid or humanoid.Health <= 0 or humanoid.Sit then return end
	local humanoid_state = humanoid:GetState()
	if humanoid_state == Enum.HumanoidStateType.Dead
		or humanoid_state == Enum.HumanoidStateType.Swimming
		or humanoid_state == Enum.HumanoidStateType.Climbing then return end
	if not self.CharacterState:CanStart("Grab") then return end

	local horizontal_normal = Vector.flatten(normal)
	if horizontal_normal.Magnitude < 0.05 then return end
	local forward_held = self.Input:IsDown(Actions.Forward)
	local is_tagged_guide = self.Climbables:IsClimbable(guide)
	-- Entering Hanging takes the Hang lease (blocking sprint and attacks) and
	-- pushes the hang pose (no AutoRotate, PlatformStand).
	if not State.enter(self, {
		kind = "Hanging",
		data = {
			CurrentClimbable = guide,
			Normal = horizontal_normal.Unit,
			HangDepthOffset = horizontal_normal.Unit * (edge_gap or Config.WallGap),
			HangPosition = position,
			CornerLockPosition = nil,
			CornerLockInputDirection = nil,
		},
	}) then
		return
	end
	-- Tagged ledges require a fresh Forward press after grabbing. A generic
	-- tall wall instead uses the held Forward intent to mantle immediately.
	if forward_held and is_tagged_guide then
		self.Latch:Block("Forward")
	else
		self.Latch:Release("Forward")
	end

	self:_position_hanging(dt)
	if forward_held and not is_tagged_guide then
		LedgeTraversal.try_mantle(self)
	end
end

-- Moves the root toward the hang target. `dt` is the frame time (0 for an
-- input-driven snap, which applies no smoothing).
function ParkourController:_position_hanging(dt)
	local hang = State.hang(self)
	local root = self.Root
	if not root or not hang then return end
	local position = hang.HangPosition
	local normal = hang.Normal

	local target = CFrame.lookAt(position, position - normal)
	local alpha = 1 - math.exp(-Config.ClimbSmoothness * math.max(dt, 0))
	local current = root.CFrame

	-- Keep lateral traversal responsive: smoothing X/Z makes A/D lag behind
	-- the validated hang point and can pull the body into a ledge during a
	-- simultaneous vertical transfer. Smooth only the vertical component.
	local smoothed_y = current.Position.Y + (position.Y - current.Position.Y) * alpha
	local smoothed_rotation = current.Rotation:Lerp(target.Rotation, alpha)
	root.CFrame = CFrame.new(position.X, smoothed_y, position.Z) * smoothed_rotation
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

function ParkourController:_step(dt)
	if self._destroyed then
		return
	end
	Metrics.begin_frame(self)
	-- Recover from lost Forward/Jump ActionEnded events (focus changes or UI
	-- capture); releasing the Jump latch also re-enables native jumping.
	self.Latch:Sync(self.Input)

	-- Track the airborne phase to release the hop guard on landing.
	local top_hop = State.top_hop(self)
	if top_hop then
		local humanoid = self.Humanoid
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			top_hop.SawAir = true
		end
		local elapsed = os.clock() - top_hop.StartedAt
		local landed = top_hop.SawAir and humanoid
			and humanoid.FloorMaterial ~= Enum.Material.Air
		if landed or elapsed >= Config.VaultTopHopTimeout then
			VaultTraversal.finish_top_hop(self, landed)
		end
	end

	local kind = State.kind(self)
	if kind == "Grounded" then
		local humanoid = self.Humanoid
		local humanoid_state = humanoid and humanoid:GetState()
		local can_probe = humanoid and humanoid.Health > 0 and not humanoid.Sit
			and humanoid_state ~= Enum.HumanoidStateType.Dead
			and humanoid_state ~= Enum.HumanoidStateType.Swimming
			and humanoid_state ~= Enum.HumanoidStateType.Climbing
		if can_probe and self.Input:IsDown(Actions.Jump) and not self.Latch:IsBlocked("Jump") then
			local climbable, normal, position, edge_gap = Queries.detect_surface(self)
			if climbable then
				self:_grab(climbable, normal, position, edge_gap, dt)
			end
		end
	elseif kind == "Hanging" then
		if not self.Input:IsDown(Actions.Jump) then
			self:_release()
			return
		end
		Traversal.traverse(self, dt)
	elseif kind == "Mantling" then
		if not LedgeTraversal.update_mantle(self, dt) then
			self:_release()
		end
	elseif kind == "Vaulting" then
		VaultTraversal.update_vault(self, dt)
	end
end

function ParkourController:_standing_height()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root then return 3 end

	local hip_height = humanoid and humanoid.HipHeight or 2
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R6 then
		-- R6's HipHeight does not include the leg length needed to place the
		-- root at its normal standing height. Include one extra root height.
		return hip_height + root.Size.Y * 1.5
	end

	return hip_height + root.Size.Y * 0.5
end

function ParkourController:GetQueryMetrics()
	return Metrics.snapshot(self)
end

function ParkourController:ResetQueryMetrics()
	Metrics.reset(self)
end

-- Lets go of whatever traversal is active and returns to Grounded. While
-- Space is still held, grabbing stays blocked until it is released.
function ParkourController:_release()
	if State.top_hop(self) then
		VaultTraversal.finish_top_hop(self, false)
	end

	local kind = State.kind(self)
	if kind == "Vaulting" then
		VaultTraversal.finish_vault(self, false)
		return
	end

	if kind == "Hanging" or kind == "Mantling" then
		State.enter(self, { kind = "Grounded" })
	end

	if self.Input:IsDown(Actions.Jump) then
		self.Latch:Block("Jump")
	else
		self.Latch:Release("Jump")
	end
end

function ParkourController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self:_release()
	self.Latch:Destroy()
	State.reset(self)

	if self.HangClearanceProbe then
		self.HangClearanceProbe:Destroy()
		self.HangClearanceProbe = nil
	end
	self.Trove:Destroy()
end

return ParkourController
