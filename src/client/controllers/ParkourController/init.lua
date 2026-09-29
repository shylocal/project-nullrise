local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)

local ParkourController = {}
ParkourController.__index = ParkourController

local Config = require(script.Config)
local VaultMath = require(script.VaultMath)
local Queries = require(script.Queries)
local Traversal = require(script.Traversal)
local LedgeTraversal = require(script.LedgeTraversal)
local VaultTraversal = require(script.VaultTraversal)

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
		CurrentClimbable = nil,
		Normal = nil,
		HangDepthOffset = nil,
		HangPosition = nil,
		AutoRotateBeforeHang = nil,
		PlatformStandBeforeHang = nil,
		GrabBlockedUntilJumpReleased = false,
		VaultJumpingEnabledBefore = nil,
		VaultAutoRotateBefore = nil,
		VaultPlatformStandBefore = nil,
		VaultHipHeightBefore = nil,
		VaultHipHeightHumanoid = nil,
		_vaultExitVelocity = nil,
		NextVaultAt = 0,
		CornerLockPosition = nil,
		CornerLockInputDirection = nil,
	}, ParkourController)

	local ok, err = pcall(self._start, self)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function ParkourController:_start()
	self.Trove:Connect(self.InputController.ActionBegan, function(action)
		if action == Actions.Jump or action == Actions.Forward or action == Actions.Backward
			or action == Actions.Left or action == Actions.Right then
			print("[ParkourDebug][input] began", action, "state", self.State,
				"root", self.Root and self.Root.Position, "move", self.Humanoid and self.Humanoid.MoveDirection)
		end
		if action == Actions.Jump then
			if self.State == "Grounded" then
				-- Space explicitly requests a vault; if no valid vault is found,
				-- the ordinary jump or ledge-grab flow remains available.
				self:_try_vault()
			end
		elseif action == Actions.Forward and self.State == "Hanging" then
			self:_try_mantle()
		elseif action == Actions.Backward and self.State == "Hanging" then
			self:_try_lower_ledge()
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		if action == Actions.Jump or action == Actions.Forward or action == Actions.Backward
			or action == Actions.Left or action == Actions.Right then
			print("[ParkourDebug][input] ended", action, "state", self.State,
				"root", self.Root and self.Root.Position, "move", self.Humanoid and self.Humanoid.MoveDirection)
		end
		if action == Actions.Jump then
			if self.GrabBlockedUntilJumpReleased then
				self.GrabBlockedUntilJumpReleased = false
				if self.Humanoid and self.State ~= "Vaulting" then
					local jumping_enabled = self.JumpingEnabledBeforeMantle
					if jumping_enabled == nil then
						jumping_enabled = self.VaultJumpingEnabledBefore
					end
					if jumping_enabled ~= nil then
						self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, jumping_enabled)
						self.JumpingEnabledBeforeMantle = nil
						self.VaultJumpingEnabledBefore = nil
					end
				end
				if self.State == "Grounded" and self.Humanoid then
					if self.AutoRotateBeforeHang ~= nil then self.Humanoid.AutoRotate = self.AutoRotateBeforeHang end
					if self.PlatformStandBeforeHang ~= nil then self.Humanoid.PlatformStand = self.PlatformStandBeforeHang end
					self.AutoRotateBeforeHang = nil
					self.PlatformStandBeforeHang = nil
				end
			end
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

function ParkourController:_cast(origin, direction, respect_can_collide)
	return Queries.cast(self, origin, direction, respect_can_collide)
end

function ParkourController:_cast_grabbable_side(origin, direction)
	return Queries.cast_grabbable_side(self, origin, direction)
end

function ParkourController:_cast_reachable_grab_top(wall_position, wall_normal, root_position, reference_y)
	return Queries.cast_reachable_grab_top(self, wall_position, wall_normal, root_position, reference_y)
end

function ParkourController:_detect_surface()
	return Queries.detect_surface(self)
end

function ParkourController:_grab(guide, normal, position)
	local humanoid = self.Humanoid
	if self.State ~= "Grounded" or not guide or not humanoid or humanoid.Health <= 0 or humanoid.Sit then return end
	local humanoid_state = humanoid:GetState()
	if humanoid_state == Enum.HumanoidStateType.Dead
		or humanoid_state == Enum.HumanoidStateType.Swimming
		or humanoid_state == Enum.HumanoidStateType.Climbing then return end
		print("[ParkourDebug][grab] accepted", guide:GetFullName(), "class", guide.ClassName,
			"normal", normal, "hangPosition", position, "humanoidState", humanoid_state)
		self.State = "Hanging"
	self.CurrentClimbable = guide
	self.Normal = normal
	self.HangDepthOffset = Vector.flatten(normal).Unit * Config.WallGap
	self.HangPosition = position

	local humanoid = self.Humanoid
	if humanoid then
		self.AutoRotateBeforeHang = humanoid.AutoRotate
		self.PlatformStandBeforeHang = humanoid.PlatformStand
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end

	if self.MovementController and self.MovementController.SetSprintBlocked then
		self.MovementController:SetSprintBlocked(true, self)
	end
	self:_position_hanging()

	-- Preserve forward intent when the player pressed W before the ledge grab.
	-- This lets a jump into a tall collidable part flow directly into the mantle.
	if self.InputController:IsDown(Actions.Forward) then
		self:_try_mantle()
	end
end

function ParkourController:_position_hanging()
	local root = self.Root
	local position = self.HangPosition
	local normal = self.Normal
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

function ParkourController:_has_hang_body_clearance(position, normal)
	return Queries.has_hang_body_clearance(self, position, normal)
end

function ParkourController:_step(dt)
	self._stepDelta = dt
	-- Recover from a lost Jump ActionEnded event (focus changes or UI capture).
	if self.GrabBlockedUntilJumpReleased and not self.InputController:IsDown(Actions.Jump) then
		self.GrabBlockedUntilJumpReleased = false
		local humanoid = self.Humanoid
		if humanoid and self.State ~= "Vaulting" then
			local enabled = self.JumpingEnabledBeforeMantle
			if enabled == nil then enabled = self.VaultJumpingEnabledBefore end
			if enabled ~= nil then humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, enabled) end
		end
		self.JumpingEnabledBeforeMantle = nil
		self.VaultJumpingEnabledBefore = nil
	end

	-- Track the airborne phase to release the hop guard on landing.
	local top_hop = self._topHopActive
	if top_hop then
		local humanoid = self.Humanoid
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			top_hop.SawAir = true
		end
		local elapsed = os.clock() - top_hop.StartedAt
		local landed = top_hop.SawAir and humanoid
			and humanoid.FloorMaterial ~= Enum.Material.Air
		if landed or elapsed >= 3 then
			self:_finish_top_hop(landed)
		end
	end

	if self.State == "Grounded" then
		if self.InputController:IsDown(Actions.Jump) and not self.GrabBlockedUntilJumpReleased then
			local climbable, normal, position = self:_detect_surface()
			if climbable then self:_grab(climbable, normal, position) end
		end
	elseif self.State == "Hanging" then
		if not self.InputController:IsDown(Actions.Jump) then
			self:_release()
			return
		end
		Traversal.traverse(self, dt)
	elseif self.State == "Mantling" then
		local root = self.Root
		self._mantleElapsed = math.min((self._mantleElapsed or 0) + math.max(dt, 0), self._mantleDuration)
		local linear = self._mantleElapsed / self._mantleDuration
		local alpha = VaultMath.smoothstep(linear)
		if root and self._mantleStart and self._mantleTarget then
			root.CFrame = self._mantleStart:Lerp(self._mantleTarget, alpha)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
		if linear >= 1 then
			self.State = "Grounded"
			self._mantleStart = nil
			self._mantleTarget = nil
			self._mantleElapsed = nil
			self._mantleDuration = nil
			-- Restore ordinary Humanoid movement when the mantle ends. The
			-- jump/grab lock is independent and remains set until Space is released.
			if self.Humanoid then
				if self.AutoRotateBeforeHang ~= nil then self.Humanoid.AutoRotate = self.AutoRotateBeforeHang end
				if self.PlatformStandBeforeHang ~= nil then self.Humanoid.PlatformStand = self.PlatformStandBeforeHang end
				self.Humanoid:ChangeState(Enum.HumanoidStateType.Running)
			end
			self.AutoRotateBeforeHang = nil
			self.PlatformStandBeforeHang = nil
			if self.MovementController then self.MovementController:SetSprintBlocked(false, self) end
		end
	elseif self.State == "Vaulting" then
		local root = self.Root
		local duration = self._vaultDuration
		if not root or not duration or not self._vaultStart or not self._vaultTarget then
			self:_finish_vault(false)
			return
		end

		self._vaultElapsed = math.min((self._vaultElapsed or 0) + math.max(dt, 0), duration)
		local linear = self._vaultElapsed / duration
		local debug_stage = math.min(4, math.floor(linear * 4))
		if self._vaultDebugLastStage ~= debug_stage then
			self._vaultDebugLastStage = debug_stage
		end
		local eased = VaultMath.smoothstep(linear)
		local base = self._vaultStart:Lerp(self._vaultTarget, eased)
		local horizontal = self._vaultStart.Position:Lerp(self._vaultTarget.Position, linear)
		local arc = VaultMath.arc_weight(linear, self._vaultArcPeakProgress) * self._vaultArcHeight
		local position = Vector3.new(horizontal.X, base.Position.Y, horizontal.Z)
		root.CFrame = CFrame.new(position + Vector3.new(0, arc, 0)) * base.Rotation

		local vault_humanoid = self.VaultHipHeightHumanoid
		local original_hip_height = self.VaultHipHeightBefore
		if vault_humanoid and vault_humanoid.Parent and original_hip_height ~= nil then
			local reduction = math.max(0, Config.VaultHipHeightReduction or 0)
			local weight = VaultMath.hip_height_weight(linear)
			local minimum_hip_height = 0
			if vault_humanoid.RigType == Enum.HumanoidRigType.R6 then
				-- R6 commonly starts at zero HipHeight, so allow a small negative
				-- relative offset to make the temporary crouch effective.
				minimum_hip_height = -0.35
			end
			vault_humanoid.HipHeight = math.max(
				minimum_hip_height,
				original_hip_height - reduction * weight
			)
		end

		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		if linear >= 1 then
			self:_finish_vault(true)
		end
	end
end


function ParkourController:_has_vault_clearance(cframe, size, obstacle)
	return Queries.has_vault_clearance(self, cframe, size, obstacle)
end

function ParkourController:_try_vault()
	return VaultTraversal.try_vault(self)
end

function ParkourController:_finish_top_hop(landed)
	return VaultTraversal.finish_top_hop(self, landed)
end

function ParkourController:_finish_vault(completed)
	return VaultTraversal.finish_vault(self, completed)
end

function ParkourController:_snapshot_hang_pose()
	return Traversal.snapshot_hang_pose(self)
end

function ParkourController:_restore_hang_pose(snapshot)
	Traversal.restore_hang_pose(self, snapshot)
end

function ParkourController:_try_lower_ledge()
	return LedgeTraversal.try_lower_ledge(self)
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

function ParkourController:_refresh_hang_contact(expected_guide, expected_top_y)
	return LedgeTraversal.refresh_hang_contact(self, expected_guide, expected_top_y)
end

function ParkourController:_get_ledge_outward_normal(top, reference_position)
	return LedgeTraversal.get_ledge_outward_normal(self, top, reference_position)
end

function ParkourController:_transfer_hang_to_ledge(top, target_normal)
	return LedgeTraversal.transfer_hang_to_ledge(self, top, target_normal)
end

function ParkourController:_get_guide_top(guide, sample_position)
	return LedgeTraversal.get_guide_top(self, guide, sample_position)
end

function ParkourController:_get_guide_tops(guide, sample_position)
	return LedgeTraversal.get_guide_tops(self, guide, sample_position)
end

function ParkourController:_try_ground_mantle(current_top, normal, tangent)
	return LedgeTraversal.try_ground_mantle(self, current_top, normal, tangent)
end

function ParkourController:_is_guide_within_mantle_search(guide, current_top, normal, tangent)
	return LedgeTraversal.is_guide_within_mantle_search(self, guide, current_top, normal, tangent)
end

function ParkourController:_try_mantle()
	return LedgeTraversal.try_mantle(self)
end

function ParkourController:_release()
	if self.State == "Hanging" or self.State == "Mantling" or self.State == "Vaulting" then
		print("[ParkourDebug][release] state", self.State, "surface",
			self.CurrentClimbable and self.CurrentClimbable:GetFullName(),
			"jumpDown", self.InputController:IsDown(Actions.Jump),
			"root", self.Root and self.Root.Position)
	end
	if self._topHopActive then
		self:_finish_top_hop(false)
	end
	if self.State == "Vaulting" then
		self:_finish_vault(false)
		return
	end
	if self.State == "Mantling" then
		self.State = "Grounded"
		self._mantleStart = nil
		self._mantleTarget = nil
		self._mantleElapsed = nil
		self._mantleDuration = nil
		local humanoid = self.Humanoid
		if humanoid then
			if self.JumpingEnabledBeforeMantle ~= nil then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, self.JumpingEnabledBeforeMantle)
				self.JumpingEnabledBeforeMantle = nil
			end
			if self.AutoRotateBeforeHang ~= nil then humanoid.AutoRotate = self.AutoRotateBeforeHang end
			if self.PlatformStandBeforeHang ~= nil then humanoid.PlatformStand = self.PlatformStandBeforeHang end
		end
		self.AutoRotateBeforeHang = nil
		self.PlatformStandBeforeHang = nil
		self.GrabBlockedUntilJumpReleased = false
		if self.MovementController then self.MovementController:SetSprintBlocked(false, self) end
		return
	end
	if self.State ~= "Hanging" then
		return
	end
	self.State = "Grounded"
	self.CurrentClimbable = nil
	self.Normal = nil
	self.HangDepthOffset = nil
	self.HangPosition = nil
	self.CornerLockPosition = nil
	self.CornerLockInputDirection = nil

	local humanoid = self.Humanoid
	if humanoid then
		if self.AutoRotateBeforeHang ~= nil then
			humanoid.AutoRotate = self.AutoRotateBeforeHang
		end
		if self.PlatformStandBeforeHang ~= nil then
			humanoid.PlatformStand = self.PlatformStandBeforeHang
		end
	end
	self.AutoRotateBeforeHang = nil
	self.PlatformStandBeforeHang = nil
	if self.MovementController then
		self.MovementController:SetSprintBlocked(false, self)
	end
end

function ParkourController:Destroy()
	self:_release()
	if self.Humanoid then
		if self.JumpingEnabledBeforeMantle ~= nil then
			self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, self.JumpingEnabledBeforeMantle)
		end
		if self.VaultJumpingEnabledBefore ~= nil then
			self.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, self.VaultJumpingEnabledBefore)
		end
		if self.AutoRotateBeforeHang ~= nil then self.Humanoid.AutoRotate = self.AutoRotateBeforeHang end
		if self.PlatformStandBeforeHang ~= nil then self.Humanoid.PlatformStand = self.PlatformStandBeforeHang end
	end
	if self.MovementController then self.MovementController:SetSprintBlocked(false, self) end
	self.GrabBlockedUntilJumpReleased = false
	if self.HangClearanceProbe then
		self.HangClearanceProbe:Destroy()
		self.HangClearanceProbe = nil
	end
	self.Trove:Destroy()
end

return ParkourController
