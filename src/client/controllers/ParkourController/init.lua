local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)

local ParkourController = {}
ParkourController.__index = ParkourController

local Config = require(script.Config)
local ClimbableQuery = require(script.ClimbableQuery)

local Queries = require(script.Queries)
local Traversal = require(script.Traversal)
local LedgeTraversal = require(script.LedgeTraversal)
local VaultTraversal = require(script.VaultTraversal)
local ParkourState = require(script.State)
local Metrics = require(script.Metrics)

function ParkourController.new(character, input_controller, movement_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		MovementController = movement_controller,
		Trove = Trove.new(),
		State = "Grounded",
		Humanoid = nil,
		BoundHumanoid = nil,
		Root = character:FindFirstChild("HumanoidRootPart"),
		GrabBlockedUntilJumpReleased = false,
		_humanoidSnapshots = {},
		_stateData = {},
		_destroyed = false,
		NextVaultAt = 0,
	}, ParkourController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function ParkourController:_start()
	self._queryMetricsEnabled = self.Character:GetAttribute("ParkourQueryMetrics") == true
	self.Trove:Connect(self.Character:GetAttributeChangedSignal("ParkourQueryMetrics"), function()
		self._queryMetricsEnabled = self.Character:GetAttribute("ParkourQueryMetrics") == true
	end)

	self.Trove:Connect(self.InputController.ActionBegan, function(action)
		if action == Actions.Jump then
			if self.State == "Grounded" then
				-- Space explicitly requests a vault; if no valid vault is found,
				-- the ordinary jump or ledge-grab flow remains available.
				VaultTraversal.try_vault(self)
			end
		elseif action == Actions.Forward and self.State == "Hanging" then
			if not self.ForwardBlockedUntilRelease then
				LedgeTraversal.try_mantle(self)
			end
		elseif action == Actions.Backward and self.State == "Hanging" then
			LedgeTraversal.try_lower_ledge(self)
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		if action == Actions.Forward then
			self.ForwardBlockedUntilRelease = false
		end
		if action == Actions.Jump then
			self:_clear_jump_block()
			if self.State == "Hanging" then
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
		if child.Name == "HumanoidRootPart" then
			self.Root = child
		elseif child:IsA("Humanoid") then
			self:_bind_humanoid(child)
		end
	end)
end

function ParkourController:_bind_character_parts()
	self.Root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self:_bind_humanoid(humanoid)
	end
end

function ParkourController:_bind_humanoid(humanoid)
	if self.BoundHumanoid == humanoid then return end
	self.BoundHumanoid = humanoid
	self.Humanoid = humanoid
	self.Trove:Connect(humanoid.Died, function()
		self:_release()
	end)
end


function ParkourController:_grab(guide, normal, position, edge_gap)
	local humanoid = self.Humanoid
	if self.State ~= "Grounded" or not guide or not humanoid or humanoid.Health <= 0 or humanoid.Sit then return end
	local humanoid_state = humanoid:GetState()
	if humanoid_state == Enum.HumanoidStateType.Dead
		or humanoid_state == Enum.HumanoidStateType.Swimming
		or humanoid_state == Enum.HumanoidStateType.Climbing then return end

	local horizontal_normal = Vector.flatten(normal)
	if horizontal_normal.Magnitude < 0.05 then return end
	if not ParkourState.transition(self, "Hanging") then return end
	local forward_held = self.InputController:IsDown(Actions.Forward)
	local is_tagged_guide = ClimbableQuery.is_climbable(guide)
	-- Tagged ledges require a fresh Forward press after grabbing. A generic
	-- tall wall instead uses the held Forward intent to mantle immediately.
	self.ForwardBlockedUntilRelease = forward_held and is_tagged_guide
	ParkourState.set_data(self, "Hanging", {
		CurrentClimbable = guide,
		Normal = horizontal_normal.Unit,
		HangDepthOffset = horizontal_normal.Unit * (edge_gap or Config.WallGap),
		HangPosition = position,
		CornerLockPosition = nil,
		CornerLockInputDirection = nil,
	})

	if self.Humanoid then
		local humanoid = self.Humanoid
		ParkourState.capture_humanoid(self, "Hang", { "AutoRotate", "PlatformStand" })
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end

	if self.MovementController and self.MovementController.SetSprintBlocked then
		self.MovementController:SetSprintBlocked(true, self)
	end
	self:_position_hanging()
	if forward_held and not is_tagged_guide then
		LedgeTraversal.try_mantle(self)
	end
end

function ParkourController:_position_hanging()
	local hang = ParkourState.get_data(self, "Hanging")
	local root = self.Root
	local position = hang and hang.HangPosition
	local normal = hang and hang.Normal
	if not root or not position or not normal then return end

	local target = CFrame.lookAt(position, position - normal)
	local dt = self._stepDelta or 1 / 60
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


function ParkourController:_clear_jump_block()
	if not self.GrabBlockedUntilJumpReleased then
		return
	end

	self.GrabBlockedUntilJumpReleased = false
	if self.State ~= "Vaulting" then
		ParkourState.restore_humanoid(self, "Mantle", { "JumpingEnabled" })
		ParkourState.restore_humanoid(self, "Vault", { "JumpingEnabled" })
	end
	if self.State == "Grounded" then
		-- This helper is used only after Jump is released; while Hanging, the
		-- caller must perform the explicit hang-release transition first.
		ParkourState.restore_humanoid(self, "Hang", { "AutoRotate", "PlatformStand" })
	end
end

function ParkourController:_step(dt)
	if self._destroyed then
		return
	end
	self._stepDelta = dt
	-- Recover from a lost Forward ActionEnded event (focus changes or UI capture).
	if self.ForwardBlockedUntilRelease and not self.InputController:IsDown(Actions.Forward) then
		self.ForwardBlockedUntilRelease = false
	end

	-- Recover from a lost Jump ActionEnded event (focus changes or UI capture).
	if self.GrabBlockedUntilJumpReleased and not self.InputController:IsDown(Actions.Jump) then
		self:_clear_jump_block()
	end

	-- Track the airborne phase to release the hop guard on landing.
	local top_hop = ParkourState.get_data(self, "TopHop")
	if top_hop then
		local humanoid = self.Humanoid
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			top_hop.SawAir = true
		end
		local elapsed = os.clock() - top_hop.StartedAt
		local landed = top_hop.SawAir and humanoid
			and humanoid.FloorMaterial ~= Enum.Material.Air
		if landed or elapsed >= 3 then
			VaultTraversal.finish_top_hop(self, landed)
		end
	end

	if self.State == "Grounded" then
		local humanoid = self.Humanoid
		local humanoid_state = humanoid and humanoid:GetState()
		local can_probe = humanoid and humanoid.Health > 0 and not humanoid.Sit
			and humanoid_state ~= Enum.HumanoidStateType.Dead
			and humanoid_state ~= Enum.HumanoidStateType.Swimming
			and humanoid_state ~= Enum.HumanoidStateType.Climbing
		if can_probe and self.InputController:IsDown(Actions.Jump) and not self.GrabBlockedUntilJumpReleased then
			local climbable, normal, position, edge_gap = Queries.detect_surface(self)
			if climbable then self:_grab(climbable, normal, position, edge_gap) end
		end
	elseif self.State == "Hanging" then
		if not self.InputController:IsDown(Actions.Jump) then
			self:_release()
			return
		end
		Traversal.traverse(self, dt)
	elseif self.State == "Mantling" then
		if not LedgeTraversal.update_mantle(self, dt) then
			self:_release()
		end
	elseif self.State == "Vaulting" then
		if not VaultTraversal.update_vault(self, dt) then
			return
		end
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

function ParkourController:_release()
	if ParkourState.get_data(self, "TopHop") then
		VaultTraversal.finish_top_hop(self, false)
	end

	local state = self.State
	if state == "Vaulting" then
		VaultTraversal.finish_vault(self, false)
		return
	end

	local was_traversing = state == "Hanging" or state == "Mantling"
	if state == "Hanging" or state == "Mantling" then
		ParkourState.transition(self, "Grounded")
	end

	if state == "Hanging" then
		ParkourState.clear_data(self, "Hanging")
	elseif state == "Mantling" then
		ParkourState.clear_data(self, "Mantling")
	end

	local jump_held = self.InputController:IsDown(Actions.Jump)
	if not jump_held then
		self:_clear_jump_block()
		ParkourState.restore_humanoid(self, "Mantle", { "JumpingEnabled" })
		ParkourState.restore_humanoid(self, "Vault", { "JumpingEnabled" })
	else
		self.GrabBlockedUntilJumpReleased = true
	end
	ParkourState.restore_humanoid(self, "Hang", { "AutoRotate", "PlatformStand" })

	if was_traversing and self.MovementController then
		self.MovementController:SetSprintBlocked(false, self)
	end
end

function ParkourController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self:_release()
	ParkourState.clear_all_data(self)
	ParkourState.restore_humanoid(self, "Hang")
	ParkourState.restore_humanoid(self, "Mantle")
	ParkourState.restore_humanoid(self, "Vault")
	self.GrabBlockedUntilJumpReleased = false

	if self.HangClearanceProbe then
		self.HangClearanceProbe:Destroy()
		self.HangClearanceProbe = nil
	end
	self.Trove:Destroy()
end

return ParkourController
