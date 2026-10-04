local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)
local SharedConfig = require(ReplicatedStorage.shared.config)

local VaultMath = require(script.Parent.VaultMath)
local State = require(script.Parent.State)
local Queries = require(script.Parent.Queries)

local Config = SharedConfig.Parkour
local MovementConfig = SharedConfig.Movement

local VaultTraversal = {}

function VaultTraversal.try_vault(self)
	if State.top_hop(self) then return false end
	if not Config.VaultEnabled then
		return false
	end
	if State.kind(self) ~= "Grounded" then
		return false
	end
	if self.Latch:IsBlocked("Jump") then
		return false
	end
	if os.clock() < self.NextVaultAt then
		return false
	end
	if not self.CharacterState:CanStart("Vault") then
		return false
	end
	if not self.Movement:IsSprinting() then
		return false
	end

	local now = os.clock()
	local root = self.Root
	local humanoid = self.Humanoid
	if not root or not humanoid or humanoid.Health <= 0
		or humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end

	-- Vaults follow actual movement. Holding Sprint while standing still is
	-- not a sprint, so a stationary Space press never starts a vault.
	local forward = Vector.flatten(humanoid.MoveDirection)
	local facing = Vector.flatten(root.CFrame.LookVector)
	if forward.Magnitude < MovementConfig.SprintMinMoveMagnitude then
		return false
	end
	forward = forward.Unit
	if facing.Magnitude >= 0.05 then
		facing = facing.Unit
	else
		facing = forward
	end

	local standing_height = self:_standing_height()
	local current_ground = Queries.cast(self, 
		root.Position + Vector3.new(0, 0.5, 0),
		Vector3.new(0, -(standing_height + 2), 0),
		true
	)
	if not current_ground or current_ground.Normal.Y < 0.5 then
		return false
	end

	local detection_origin = Vector3.new(
		root.Position.X,
		current_ground.Position.Y + Config.VaultDetectionHeight,
		root.Position.Z
	)
	local half_width = math.max(0, math.min(
		Config.VaultDetectionHalfWidth,
		math.max(root.Size.X * 0.75, 0.75)
	))
	local function probe_obstacle(direction)
		local right = direction:Cross(Vector3.yAxis)
		if right.Magnitude < 0.05 then
			return nil
		end
		right = right.Unit
		-- Prefer the center ray: side probes are fallback coverage only, so a
		-- nearby unrelated prop cannot mask the wall directly in front.
		local center_hit = Queries.cast(self, 
			detection_origin,
			direction * Config.VaultDetectionDistance,
			true
		)
		if center_hit then
			return center_hit
		end
		local offsets = {
			right * half_width,
			-right * half_width,
			Vector3.new(0, -0.2, 0),
			Vector3.new(0, 0.45, 0),
		}
		local best_hit = nil
		for _, offset in ipairs(offsets) do
			local hit = Queries.cast(self, 
				detection_origin + offset,
				direction * Config.VaultDetectionDistance,
				true
			)
			if hit and (not best_hit or hit.Distance < best_hit.Distance) then
				best_hit = hit
			end
		end
		return best_hit
	end
	local obstacle_hit = probe_obstacle(forward)
	-- If movement is diagonal to the body's facing and its ray misses, also
	-- check the facing axis. Keep the movement vector for the vault trajectory
	-- whenever that primary probe successfully finds the obstacle.
	if not obstacle_hit and (facing - forward).Magnitude > 0.15 then
		local facing_hit = probe_obstacle(facing)
		if facing_hit then
			obstacle_hit = facing_hit
			forward = facing
		end
	end
	if not obstacle_hit then
		return false
	end

	local obstacle = obstacle_hit.Instance
	if not obstacle:IsA("BasePart") or not obstacle.CanCollide
		or obstacle.CollisionGroup == SharedConfig.World.CollisionGroups.Climbable
		or self.Climbables:IsClimbable(obstacle) then
		return false
	end

	local obstacle_model = obstacle:FindFirstAncestorOfClass("Model")
	if obstacle_model and obstacle_model:FindFirstChildOfClass("Humanoid") then
		return false
	end

	-- Use the detected collidable part's own bounds. Its ancestor Model may
	-- be a container for an entire map, so using GetBoundingBox() there can
	-- inflate the far edge and push the landing point beyond the hop range.
	local half_depth = (
		math.abs(obstacle.CFrame.RightVector:Dot(forward)) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector:Dot(forward)) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector:Dot(forward)) * obstacle.Size.Z
	) * 0.5
	local center_distance = (obstacle.Position - root.Position):Dot(forward)
	local near_edge_distance = center_distance - half_depth
	local far_edge_distance = center_distance + half_depth
	if far_edge_distance <= 0 then
		return false
	end

	-- Sample the top close to the near edge, rather than aiming at the center
	-- of a long obstacle. This creates a short hop onto broad surfaces.
	local top_inset = math.min(
		Config.VaultTopLandingInset,
		math.max(0.25, half_depth * 0.75)
	)
	local top_sample_distance = near_edge_distance + top_inset
	local hit_relative = obstacle_hit.Position - root.Position
	local lateral_offset = hit_relative - forward * hit_relative:Dot(forward)
	local projected_top_sample = root.Position + forward * top_sample_distance + lateral_offset

	local top_params = self.Query:Include(self.Query.Params.VaultTop, obstacle)

	-- At oblique approaches, a wall-face hit can be near a side edge. Try
	-- vertical samples progressively inside from that exact impact point before
	-- using the projected near-edge sample; this avoids missing the top surface.
	local top_samples = {
		obstacle_hit.Position + forward * 0.25,
		obstacle_hit.Position + forward * 0.55,
		obstacle_hit.Position + forward * 0.9,
		projected_top_sample,
	}
	local top = nil
	for _, sample in ipairs(top_samples) do
		local top_origin = Vector3.new(
			sample.X,
			obstacle.Position.Y + obstacle.Size.Magnitude + 4,
			sample.Z
		)
		local candidate = self.Query:Raycast(
			top_origin,
			Vector3.new(0, -(obstacle.Size.Magnitude * 2 + 8), 0),
			top_params
		)
		if candidate and candidate.Normal.Y >= 0.5 then
			top = candidate
			break
		end
	end
	if not top then
		return false
	end

	local current_ground_y = current_ground.Position.Y
	local obstacle_height = top.Position.Y - current_ground_y
	if obstacle_height < Config.VaultMinHeight or obstacle_height > Config.VaultMaxHeight then
		return false
	end

	-- Measure the part's full horizontal span, not only its thickness along
	-- the approach. Long platforms/walls use a physics-driven hop onto the
	-- sampled top instead of the scripted vault path through their geometry.
	local obstacle_lateral = Vector3.new(-forward.Z, 0, forward.X)
	local lateral_half_depth = (
		math.abs(obstacle.CFrame.RightVector:Dot(obstacle_lateral)) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector:Dot(obstacle_lateral)) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector:Dot(obstacle_lateral)) * obstacle.Size.Z
	) * 0.5
	local obstacle_length = math.max(half_depth * 2, lateral_half_depth * 2)
	local long_obstacle_threshold = Config.VaultLongObstacleHopLength

	-- Detect a continuous walkable surface directly beneath the obstacle.
	-- Exclude the obstacle itself so the downward probes can reach its support
	-- floor, while retaining other world geometry in the query.
	local obstacle_vertical_half = (
		math.abs(obstacle.CFrame.RightVector.Y) * obstacle.Size.X
		+ math.abs(obstacle.CFrame.UpVector.Y) * obstacle.Size.Y
		+ math.abs(obstacle.CFrame.LookVector.Y) * obstacle.Size.Z
	) * 0.5
	local obstacle_bottom_y = obstacle.Position.Y - obstacle_vertical_half
	local support_tolerance = math.max(0, Config.VaultGroundSupportTolerance)
	local support_params = self.Query:Exclude(self.Query.Params.VaultSupport, { obstacle })
	local support_origin_y = top.Position.Y + standing_height + 2
	local support_ray = Vector3.new(
		0,
		-(support_origin_y - (obstacle_bottom_y - support_tolerance)),
		0
	)
	local support_forward_offsets = { -0.65, 0, 0.65 }
	local support_lateral_offsets = { -0.8, -0.4, 0, 0.4, 0.8 }
	local support_count = 0
	local support_total = #support_forward_offsets * #support_lateral_offsets
	for _, forward_factor in ipairs(support_forward_offsets) do
		for _, lateral_factor in ipairs(support_lateral_offsets) do
			local sample_position = obstacle.Position
				+ forward * (half_depth * forward_factor)
				+ obstacle_lateral * (lateral_half_depth * lateral_factor)
			local support_origin = Vector3.new(sample_position.X, support_origin_y, sample_position.Z)
			local support_hit = self.Query:Raycast(
				support_origin,
				support_ray,
				support_params
			)
			local supported = support_hit ~= nil
				and support_hit.Normal.Y >= 0.5
				and math.abs(support_hit.Position.Y - obstacle_bottom_y) <= support_tolerance
			if supported then
				support_count += 1
			end
		end
	end
	local has_continuous_ground_beneath = support_count == support_total
	-- Ground support alone is not enough to identify a platform: ordinary thin
	-- walls also sit on continuous floor. Require enough top depth along the
	-- travel axis for the character to land before routing a supported obstacle
	-- to the physics hop. Very long obstacles retain their dedicated hop route.
	local top_landing_depth = half_depth * 2
	local minimum_top_hop_depth = math.max(
		Config.VaultMinTopHopDepth,
		root.Size.Z * 1.5
	)
	-- The projected travel depth grows when a long, thin wall is approached
	-- diagonally. Measure the part's intrinsic horizontal footprint axes too,
	-- so yaw/approach angle cannot make a narrow wall look like a landing deck.
	local local_x_footprint_depth = Vector.flatten(obstacle.CFrame.RightVector).Magnitude * obstacle.Size.X
	local local_z_footprint_depth = Vector.flatten(obstacle.CFrame.LookVector).Magnitude * obstacle.Size.Z
	local minimum_footprint_depth = math.min(local_x_footprint_depth, local_z_footprint_depth)
	local has_usable_top_depth = top_landing_depth >= minimum_top_hop_depth
		and minimum_footprint_depth >= minimum_top_hop_depth
	local is_long_obstacle = obstacle_length >= long_obstacle_threshold
		and minimum_footprint_depth >= minimum_top_hop_depth
	local use_top_hop = is_long_obstacle
		or (has_continuous_ground_beneath and has_usable_top_depth)
	-- Top-hops require a genuinely wide horizontal footprint, even for long
	-- parts. This prevents diagonal approaches from inflating a thin wall's
	-- projected travel depth and misclassifying it as a landing platform.
	if use_top_hop then
		local top_target = Vector3.new(
			top.Position.X,
			top.Position.Y + standing_height - 0.05,
			top.Position.Z
		)
		-- Let the Humanoid's normal sprint movement provide horizontal
		-- travel. Previously forcing a large X/Z velocity here could tunnel
		-- through broad collidable parts instead of letting physics resolve
		-- contact with their side. Set vertical speed from the exact rise to
		-- this obstacle's top, rather than using the character's default jump
		-- speed, which can launch much higher than shorter obstacles require.
		local gravity = math.max(Workspace.Gravity, 1)
		local height_margin = math.max(0, Config.VaultTopHopHeightMargin)
		local target_rise = math.max(0, top_target.Y - root.Position.Y)
		local required_vertical_speed = math.sqrt(2 * gravity * (target_rise + height_margin))
		local current_velocity = root.AssemblyLinearVelocity
		local current_horizontal_velocity = Vector.flatten(current_velocity)
		local current_forward_speed = current_horizontal_velocity:Dot(forward)
		local is_supported_platform_hop = has_continuous_ground_beneath
			and has_usable_top_depth
			and not is_long_obstacle
		local forward_boost = is_supported_platform_hop
			and math.max(0, Config.VaultTopHopForwardBoostSpeed)
			or 0
		local sprint_speed = math.max(0, humanoid.WalkSpeed)
		local hop_horizontal_velocity = current_horizontal_velocity
		if is_supported_platform_hop then
			-- Keep the existing lateral drift and ensure the character carries
			-- sprint momentum onto a supported raised surface, with a modest
			-- additional forward impulse. Long collision-sensitive obstacles
			-- intentionally retain their unboosted horizontal velocity.
			local target_forward_speed = math.max(current_forward_speed, sprint_speed) + forward_boost
			hop_horizontal_velocity += forward * (target_forward_speed - current_forward_speed)
		end
		local hop_vertical_speed = math.max(
			0,
			current_velocity.Y,
			required_vertical_speed
		)

		self.NextVaultAt = now + Config.VaultCooldown
		if self.Input:IsDown(Actions.Jump) then
			self.Latch:Block("Jump")
		end
		local requested_velocity = Vector3.new(
			hop_horizontal_velocity.X,
			hop_vertical_speed,
			hop_horizontal_velocity.Z
		)
		VaultTraversal.start_top_hop(self)
		humanoid.Jump = true
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		-- Apply calculated vertical and forward velocity. The Humanoid physics
		-- solver remains responsible for contact and landing.
		root.AssemblyLinearVelocity = requested_velocity
		return true
	end

	local target_position = nil
	local hop_distance = far_edge_distance + Config.VaultLandingGap
	local landing_origin_y = math.max(root.Position.Y, top.Position.Y)
		+ standing_height + Config.VaultMaxHeight + 2
	-- The origin rises with the obstacle top. A fixed ray length can therefore
	-- stop at (or above) the starting floor for taller walls, making every
	-- far-side probe miss otherwise valid ground. Extend below the known floor
	-- by the landing-height tolerance plus a safety margin.
	local landing_ray = Vector3.new(
		0,
		-(landing_origin_y - current_ground_y + Config.VaultLandingHeightTolerance + 1),
		0
	)
	-- Continue along the exact lane that detected the obstacle. Side probes
	-- can hit a wall away from the character's centerline, so dropping this
	-- offset would aim the far-side landing back into the wall footprint.
	local landing_lateral = Vector.flatten(hit_relative) - forward * Vector.flatten(hit_relative):Dot(forward)
	local function is_obstacle_part(instance)
		-- Exclude only the actual hit part. Its ancestor Model may also contain
		-- legitimate floor geometry used by the far-side landing ray.
		return instance == obstacle
	end

	-- Prefer ground beyond the far edge. Begin with nearby probes, then
	-- continue through the remaining hop budget. The detected part can be only
	-- one segment of a wider wall, so a fixed six-stud search can stop before
	-- reaching the actual far side and incorrectly reject every tall-wall vault.
	local landing_extra_distances = { 0, 0.75, 1.5, 2.5, 4, 6 }
	-- Keep scripted vaults from traversing an entire long obstacle when
	-- approached along its side. This cap applies to the root-to-landing
	-- displacement and is the only scripted-vault distance limit.
	local max_vault_distance = Config.VaultMaxOverDistance
	local max_landing_extra = math.max(0, max_vault_distance - hop_distance)
	local next_landing_extra = 6.75
	while next_landing_extra < max_landing_extra do
		table.insert(landing_extra_distances, next_landing_extra)
		next_landing_extra += 0.75
	end
	for _, extra_distance in ipairs(landing_extra_distances) do
		local landing_distance = hop_distance + extra_distance
		if landing_distance <= max_vault_distance then
			for _, lateral_adjustment in ipairs({ 0, -0.75, 0.75 }) do
				local side = forward:Cross(Vector3.yAxis)
				local landing_xz = root.Position + forward * landing_distance + landing_lateral
				if side.Magnitude > 0.05 then
					landing_xz += side.Unit * lateral_adjustment
				end
				-- Enforce the cap on the real horizontal displacement too;
				-- the lateral fan otherwise adds a small amount beyond the cap.
				local actual_hop_distance = Vector.flatten(landing_xz - root.Position).Magnitude
				if actual_hop_distance <= max_vault_distance + 1e-4 then
					local landing_ground = Queries.cast(self, Vector3.new(landing_xz.X, landing_origin_y, landing_xz.Z), landing_ray, true)
					if landing_ground
						and landing_ground.Normal.Y >= 0.5
						and math.abs(landing_ground.Position.Y - current_ground_y) <= Config.VaultLandingHeightTolerance
						and not is_obstacle_part(landing_ground.Instance) then
						target_position = Vector3.new(
							landing_ground.Position.X,
							landing_ground.Position.Y + standing_height - 0.05,
							landing_ground.Position.Z
						)
						break
					end
				end
			end
			if target_position then
				break
			end
		end
	end

	-- Taller walls should be cleared rather than converted into a hop onto
	-- their top. If safe far-side ground is unavailable, decline that vault
	-- instead of silently changing its destination.
	if not target_position
		and obstacle_height >= (Config.VaultFarSideOnlyHeight) then
		return false
	end

	-- Preserve the short top landing for lower, broad obstacles when no
	-- validated far-side floor is available.
	if not target_position then
		target_position = Vector3.new(
			top.Position.X,
			top.Position.Y + standing_height - 0.05,
			top.Position.Z
		)
	end

	local start_cframe = root.CFrame
	local target_cframe = CFrame.lookAt(target_position, target_position + forward)
	local midpoint_y = (start_cframe.Position.Y + target_cframe.Position.Y) * 0.5
	local horizontal_vault_distance = math.max(
		Vector.flatten(target_position - start_cframe.Position):Dot(forward),
		0.1
	)
	-- Place the apex above the obstacle's center, even when the vault begins
	-- several studs before it because of the longer detection range.
	local tall_height_factor = math.clamp(obstacle_height - 2, 0, 2)
	local arc_peak_progress = math.clamp(
		center_distance / horizontal_vault_distance - tall_height_factor * 0.06,
		0.2,
		0.92
	)
	-- Taller walls get an earlier lift and extra apex clearance so the root
	-- collider clears the face before the forward trajectory reaches it.
	local tall_obstacle_clearance = tall_height_factor
		* math.max(0, Config.VaultTallObstacleClearancePerStud)
	local required_apex_y = top.Position.Y + root.Size.Y * 0.5
		+ Config.VaultObstacleClearance + tall_obstacle_clearance
	local arc_height = math.max(Config.VaultMinArcHeight, required_apex_y - midpoint_y)
	if arc_height > Config.VaultMaxArcHeight then
		return false
	end

	-- Reject low ceilings and blocked landing space before committing.
	local clearance_size = Vector3.new(
		root.Size.X + 0.5,
		root.Size.Y + 0.25,
		root.Size.Z + 0.5
	)
	for _, alpha in ipairs({ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1 }) do
		local eased = VaultMath.smoothstep(alpha)
		local base = start_cframe:Lerp(target_cframe, eased)
		local horizontal = start_cframe.Position:Lerp(target_cframe.Position, alpha)
		local arc = VaultMath.arc_weight(alpha, arc_peak_progress) * arc_height
		local sample_position = Vector3.new(horizontal.X, base.Position.Y, horizontal.Z)
		local sample_cframe = CFrame.new(
			sample_position + Vector3.new(0, arc, 0)
		) * base.Rotation
		local clear = Queries.has_vault_clearance(self, sample_cframe, clearance_size, obstacle)
		if not clear then
			return false
		end
	end

	-- Script the vault arc, then hand the player back the forward speed they
	-- had while sprinting. Humanoid.WalkSpeed is captured before sprint is
	-- temporarily blocked; actual momentum above that speed is preserved.
	local horizontal_velocity = Vector.flatten(root.AssemblyLinearVelocity)
	local forward_speed = horizontal_velocity:Dot(forward)
	local sprint_speed = math.max(0, humanoid.WalkSpeed)
	if forward_speed < sprint_speed then
		horizontal_velocity += forward * (sprint_speed - forward_speed)
	end
	local forward_boost = math.max(0, Config.VaultForwardBoostSpeed)
	horizontal_velocity += forward * forward_boost
	-- Scale the scripted traversal time to the active sprint speed. A small
	-- floor keeps very short vaults from snapping, while longer hops retain
	-- approximately the same horizontal pace as the approach.
	local vault_distance = (target_position - start_cframe.Position).Magnitude
	local vault_duration = Config.VaultDuration
	local vault_speed = sprint_speed + forward_boost
	if vault_speed > 0.1 then
		vault_duration = math.max(0.2, vault_distance / vault_speed)
	end
	-- Add airtime only for taller walls; low vaults retain their existing pace.
	vault_duration += tall_height_factor
		* math.max(0, Config.VaultTallDurationPerStud)
	vault_duration *= math.clamp(Config.VaultDurationMultiplier, 0.5, 1.5)

	-- Entering Vaulting takes the Vault lease (blocking sprint) and pushes the
	-- pose and disabled-jump overrides; read sprint speed before this point.
	if not State.enter(self, {
		kind = "Vaulting",
		data = {
			ExitVelocity = horizontal_velocity,
			Start = start_cframe,
			Target = target_cframe,
			Elapsed = 0,
			Duration = vault_duration,
			ArcHeight = arc_height,
			ArcPeakProgress = arc_peak_progress,
			Obstacle = obstacle,
		},
	}) then
		return false
	end
	self.NextVaultAt = now + Config.VaultCooldown
	if self.Input:IsDown(Actions.Jump) then
		self.Latch:Block("Jump")
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

function VaultTraversal.update_vault(self, dt)
	local root = self.Root
	local vault = State.vault(self)
	if not root or not vault then
		VaultTraversal.finish_vault(self, false)
		return false
	end

	local duration = vault.Duration
	vault.Elapsed = math.min(vault.Elapsed + math.max(dt, 0), duration)
	local linear = vault.Elapsed / duration
	local eased = VaultMath.smoothstep(linear)
	local base = vault.Start:Lerp(vault.Target, eased)
	local horizontal = vault.Start.Position:Lerp(vault.Target.Position, linear)
	local arc = VaultMath.arc_weight(linear, vault.ArcPeakProgress) * vault.ArcHeight
	local position = Vector3.new(horizontal.X, base.Position.Y, horizontal.Z)
	local physical_exit_progress = math.clamp(Config.VaultPhysicalExitProgress, 0.05, 0.95)
	local body = State.resources(self).Body
	if linear < physical_exit_progress then
		root.CFrame = CFrame.new(position + Vector3.new(0, arc, 0)) * base.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	else
		-- Re-enable normal Humanoid control for the physical exit phase. The
		-- Vault override keeps the original value for cleanup/finish.
		if body then
			body:Set("PlatformStand", false)
		end
		-- Hand the final approach back to Roblox physics before reaching the
		-- authored endpoint. This preserves the forward impulse through the
		-- landing instead of pinning the root to the last curve samples.
		local exit_velocity = vault.ExitVelocity
		local current_velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(
			exit_velocity.X,
			current_velocity.Y,
			exit_velocity.Z
		)
	end

	local vault_humanoid = self.Humanoid
	if body and vault_humanoid and vault_humanoid.Parent then
		local original_hip_height = self.CharacterState:Overrides(vault_humanoid):Base("HipHeight")
		local reduction = math.max(0, Config.VaultHipHeightReduction)
		local weight = VaultMath.hip_height_weight(linear)
		local minimum_hip_height = 0
		if vault_humanoid.RigType == Enum.HumanoidRigType.R6 then
			-- R6 commonly starts at zero HipHeight, so allow a small negative
			-- relative offset to make the temporary crouch effective.
			minimum_hip_height = -reduction
		end
		body:Set("HipHeight", math.max(
			minimum_hip_height,
			original_hip_height - reduction * weight
		))
	end

	if linear >= 1 then
		VaultTraversal.finish_vault(self, true)
	end

	return true
end

-- Starts tracking a top-hop launch: the Grounded state carries the TopHop
-- record, which holds the TopHop lease (blocking re-vaults) until landing or
-- timeout, and zeroes the native jump impulse until the Humanoid leaves the
-- launch's Jumping state.
function VaultTraversal.start_top_hop(self)
	return State.enter(self, {
		kind = "Grounded",
		TopHop = {
			StartedAt = os.clock(),
			SawAir = false,
		},
	})
end

-- Restores the native jump setting zeroed for the top-hop launch. The TopHop
-- record itself stays until landing so it keeps guarding against re-vaults.
function VaultTraversal.restore_top_hop_jump(self)
	State.restore_top_hop_jump(self)
end

function VaultTraversal.finish_top_hop(self, _landed)
	if not State.top_hop(self) then
		return
	end
	State.enter(self, { kind = "Grounded" })
end

function VaultTraversal.finish_vault(self, completed)
	local vault = State.vault(self)
	if not vault then
		return
	end
	local exit_velocity = vault.ExitVelocity

	-- Take the disabled-jump handle before leaving Vaulting so it can outlive
	-- the state when Space is still held after a completed vault.
	local resources = State.resources(self)
	local jump_handle = resources.Jump
	resources.Jump = nil
	State.enter(self, { kind = "Grounded" })

	local jump_held = completed and self.Input:IsDown(Actions.Jump)
	if jump_held then
		self.Latch:Block("Jump", if jump_handle then { jump_handle } else nil)
	else
		if not completed then
			self.Latch:Release("Jump")
		end
		if jump_handle then
			jump_handle:Pop()
		end
	end

	local humanoid = self.Humanoid
	if humanoid and humanoid.Parent then
		humanoid.Jump = false
		if completed and humanoid.Health > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end

	-- The scripted CFrame path zeroes physics velocity while airborne. Restore
	-- horizontal sprint momentum at the landing handoff so the vault does not
	-- leave the character stationary; preserve any vertical landing velocity.
	local root = self.Root
	if completed and root and root.Parent then
		local vertical_velocity = root.AssemblyLinearVelocity.Y
		root.AssemblyLinearVelocity = Vector3.new(
			exit_velocity.X,
			vertical_velocity,
			exit_velocity.Z
		)
	end
end

return VaultTraversal
