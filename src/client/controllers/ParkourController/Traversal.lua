local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)
local ClimbableQuery = require(script.Parent.ClimbableQuery)

local Traversal = {}

local function debug_log(self, key, interval, ...)
	local now = os.clock()
	self._parkourDebugTimes = self._parkourDebugTimes or {}
	if now - (self._parkourDebugTimes[key] or 0) < interval then return end
	self._parkourDebugTimes[key] = now
	print("[ParkourDebug][" .. key .. "]", ...)
end

function Traversal.get_traverse_speed(self)
	local speed = Config.TraverseSpeed
	if self.InputController:IsDown(Actions.Sprint) then
		speed *= Config.TraverseSprintMultiplier
	end
	return speed
end
function Traversal.snapshot_hang_pose(self)
	local root = self.Root
	return {
		CurrentClimbable = self.CurrentClimbable,
		Normal = self.Normal,
		HangDepthOffset = self.HangDepthOffset,
		HangPosition = self.HangPosition,
		CornerLockPosition = self.CornerLockPosition,
		CornerLockInputDirection = self.CornerLockInputDirection,
		CFrame = root and root.CFrame,
	}
end
function Traversal.restore_hang_pose(self, snapshot)
	self.CurrentClimbable = snapshot.CurrentClimbable
	self.Normal = snapshot.Normal
	self.HangDepthOffset = snapshot.HangDepthOffset
	self.HangPosition = snapshot.HangPosition
	self.CornerLockPosition = snapshot.CornerLockPosition
	self.CornerLockInputDirection = snapshot.CornerLockInputDirection
	local root = self.Root
	if root and snapshot.CFrame then
		root.CFrame = snapshot.CFrame
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end
function Traversal.traverse(self, dt)
	local root = self.Root
	local climbable = self.CurrentClimbable
	local normal = self.Normal
	if not root or not climbable or not normal or not climbable:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	-- Generic tall-wall catches are a one-way mantle interaction, not a
	-- tagged ledge route. W invokes the tall-wall mantle; A/D stays disabled.
	if not ClimbableQuery.is_climbable(climbable) then
		self:_position_hanging()
		return
	end

	local active_top_y = self.HangPosition.Y + Config.HangDrop

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		local pose_snapshot = Traversal.snapshot_hang_pose(self)
		local tangent = Vector.flatten(root.CFrame.RightVector)
		if tangent.Magnitude < 0.05 then
			tangent = Vector.flatten(Vector3.yAxis:Cross(normal))
		end
		if tangent.Magnitude < 0.05 then
			self:_position_hanging()
			return
		end
		tangent = tangent.Unit

		-- Roblox cylinders run along local X. For an upright cylinder that
		-- axis is vertical; the previous predicate accidentally selected a
		-- horizontal cylinder and skipped the common upright case.
		local cylinder = climbable:IsA("BasePart")
			and climbable.Shape == Enum.PartType.Cylinder
			and math.abs(climbable.CFrame.RightVector.Y) >= 0.75
			and climbable
		if cylinder then
			local axis = cylinder.CFrame.RightVector
			local center = cylinder.Position
			local radial = Vector.flatten(root.Position - center)
			if radial.Magnitude < 0.05 then
				radial = -Vector.flatten(normal)
			end
			if radial.Magnitude >= 0.05 then
				radial = radial.Unit
				local radius = math.max(cylinder.Size.Y, cylinder.Size.Z) * 0.5
				local arc = Traversal.get_traverse_speed(self) * math.max(dt, 0)
				local angular_tangent = Vector.flatten(Vector3.yAxis:Cross(radial))
				local travel_tangent = tangent * direction
				local turn_sign = angular_tangent:Dot(travel_tangent) >= 0 and 1 or -1
				local angle = arc / math.max(radius + Config.WallGap, 0.1) * turn_sign
				local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(radial)
				local sample = center + rotated * radius
				local top = self:_get_guide_top(climbable, sample)
				if top and top.Normal.Y >= 0.5 then
					local next_normal = Vector.flatten(sample - center)
					if next_normal.Magnitude >= 0.05 then
						next_normal = next_normal.Unit
						local next_position = Vector3.new(top.Position.X, self.HangPosition.Y, top.Position.Z)
							+ next_normal * Config.WallGap
						local clear = self:_has_hang_body_clearance(next_position, next_normal)
						if clear then
							self.Normal = next_normal
							self.HangDepthOffset = next_normal * Config.WallGap
							self.HangPosition = next_position
						else
							Traversal.restore_hang_pose(self, pose_snapshot)
						end
					end
				end
			end
			debug_log(self, "cylinder-traverse", 0.5, "dir", direction,
				"surface", climbable:GetFullName(), "top", top and top.Instance:GetFullName(),
				"nextNormal", self.Normal, "hangPosition", self.HangPosition)
			self:_position_hanging()
			return
		end

		-- During a smoothed W/S transfer, root.Position is intentionally between
		-- the source and destination heights. Lateral contact probes must use
		-- the logical hang target so they sample the destination ledge consistently.
		local candidate_position = self.HangPosition
			+ tangent * direction * Traversal.get_traverse_speed(self) * math.max(dt, 0)
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = self:_cast(
			probe_origin,
			-normal * (Config.WallGap + Config.SurfaceProbe)
		)
		local top = probe
			and self:_cast_reachable_grab_top(probe.Position, probe.Normal, candidate_position, active_top_y)
		local next_climbable = top
			and (ClimbableQuery.get_guide(top.Instance) or top.Instance)
		local same_height = top
			and math.abs(top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
			and top.Normal.Y >= 0.5
		local horizontal_normal = probe and Vector.flatten(probe.Normal) or Vector3.zero

		-- Probe a wider corner fan when the character reaches a corner. Both
		-- handednesses are considered because a route may wrap around either
		-- a convex outside corner or a concave inside corner.
		local movement_tangent = tangent * direction
		local corner_locked = false
		if self.CornerLockPosition then
			corner_locked = Vector.flatten(root.Position - self.CornerLockPosition).Magnitude < Config.CornerLockDistance
			if self.CornerLockInputDirection
				and direction ~= self.CornerLockInputDirection then
				-- An intentional left/right reversal means the player wants to
				-- turn back now. Drop the seam lock immediately; same-direction
				-- movement remains locked until the character clears the corner.
				corner_locked = false
				self.CornerLockPosition = nil
				self.CornerLockInputDirection = nil
			elseif not corner_locked then
				self.CornerLockPosition = nil
				self.CornerLockInputDirection = nil
			end
		end
		local corner_turn_normals = {}
		if not corner_locked then
			-- The face facing the direction of travel is preferred. The opposite
			-- face remains a fallback for concave layouts, not an equal candidate.
			corner_turn_normals = { movement_tangent, -movement_tangent }
		end
		local corner_longitudinal_offsets = {
			-normal * 1.8,
			-normal * 0.9,
			normal * 0.9,
			normal * 1.8,
		}
		local best_corner = nil
		local best_corner_score = math.huge
		local corner_clearance = math.max(root.Size.X, root.Size.Z) * 0.5 + 0.1

		for _, turn_normal in ipairs(corner_turn_normals) do
			for _, longitudinal_offset in ipairs(corner_longitudinal_offsets) do
				local corner_origin = candidate_position
					+ Vector3.new(0, 1.5, 0)
					+ longitudinal_offset
					+ turn_normal * (Config.WallGap + 0.75)
				local corner_probe = self:_cast_climbable_side(
					corner_origin,
					-turn_normal * (Config.WallGap + Config.SurfaceProbe + 2)
				)
				if corner_probe then
					local corner_normal = Vector.flatten(corner_probe.Normal)
					if corner_normal.Magnitude >= 0.05 then
						corner_normal = corner_normal.Unit
						local alignment_to_old = math.abs(corner_normal:Dot(normal))
						local alignment_to_turn = corner_normal:Dot(turn_normal)
						local along_movement = Vector.flatten(corner_probe.Position - candidate_position):Dot(movement_tangent)
						local perpendicular = alignment_to_old <= 0.45
							and alignment_to_turn >= 0.55
						local near_corner = along_movement >= -1.5
							and along_movement <= Config.WallGap + Config.SurfaceProbe + 1.5

						if perpendicular and near_corner then
							local corner_top = self:_cast_reachable_grab_top(
								corner_probe.Position,
								corner_probe.Normal,
								root.Position,
								root.Position.Y + Config.HangDrop
							)
							local corner_guide = corner_top
								and (ClimbableQuery.get_guide(corner_top.Instance) or corner_top.Instance)
							local corner_height_ok = corner_top
								and math.abs(corner_top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
								and corner_top.Normal.Y >= 0.5

							if corner_top and corner_guide and corner_height_ok then
								-- The root is centered at the corner seam after a 90-degree
								-- turn, so its body can still overlap the old wall. Move one
								-- half-root-width along the old wall's outward axis, then
								-- confirm that the destination guide actually covers that
								-- landing column before accepting the corner.
								local cleared_sample = corner_top.Position + normal * corner_clearance
								local cleared_top = nil
								local cleared_distance = math.huge
								for _, candidate_top in ipairs(self:_get_guide_tops(corner_guide, cleared_sample)) do
									local distance = math.abs(candidate_top.Position.Y - active_top_y)
									if distance < cleared_distance then
										cleared_top = candidate_top
										cleared_distance = distance
									end
								end
								local clearance_valid = cleared_top
									and cleared_distance <= Config.TraverseHeightTolerance
									and Vector.flatten(cleared_top.Position - cleared_sample).Magnitude <= 1.25
								if clearance_valid then
									local candidate_hang = cleared_top.Position
										+ corner_normal * Config.WallGap
										- Vector3.new(0, Config.HangDrop, 0)
									local candidate_clear = self:_has_hang_body_clearance(candidate_hang, corner_normal)
									if candidate_clear then
									local turn_side_penalty = turn_normal:Dot(movement_tangent) >= 0 and 0 or 100
									local score = turn_side_penalty
										+ math.abs(along_movement)
										+ alignment_to_old * 2
										+ math.abs(longitudinal_offset.Magnitude) * 0.05
									if score < best_corner_score then
										best_corner = {
											Top = cleared_top,
											Guide = corner_guide,
											Normal = corner_normal,
											WallInstance = corner_probe.Instance,
										}
										best_corner_score = score
									end
									end
								end
							end
						end
					end
				end
			end
		end

		local is_corner_transfer = best_corner ~= nil
		if is_corner_transfer then
			top = best_corner.Top
			next_climbable = best_corner.Guide
			same_height = true
			horizontal_normal = best_corner.Normal
					end

		if horizontal_normal.Magnitude >= 0.05 then
			horizontal_normal = horizontal_normal.Unit
		else
			horizontal_normal = normal
		end
		-- A normal side-ray can still see the previous wall at the corner seam.
		-- Never let that stale face overwrite an already-acquired perpendicular
		-- face; only a validated corner probe may rotate the hanging normal.
		local probe_normal_aligned = horizontal_normal:Dot(normal) >= 0.65

		if top and next_climbable == climbable and same_height
			and (is_corner_transfer or probe_normal_aligned) then
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * Config.WallGap
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		elseif top and next_climbable and next_climbable ~= climbable and same_height
			and (is_corner_transfer or probe_normal_aligned) then
			self.CurrentClimbable = next_climbable
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * Config.WallGap
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		else
					end

		-- Exempt only the exact wall part supporting the hang; the top is below the root by Config.HangDrop and must not mask a thick-wall collision.
		local pose_changed = (self.HangPosition - pose_snapshot.HangPosition).Magnitude > 1e-3
			or self.Normal:Dot(pose_snapshot.Normal) < 0.999
		local midpoint_clear = true
		if is_corner_transfer and self.Normal:Dot(pose_snapshot.Normal) < 0.707 then
			local midpoint = pose_snapshot.HangPosition:Lerp(self.HangPosition, 0.5)
			local midpoint_normal = Vector.flatten(pose_snapshot.Normal + self.Normal)
			if midpoint_normal.Magnitude < 0.05 then midpoint_normal = self.Normal end
			midpoint_clear = self:_has_hang_body_clearance(midpoint, midpoint_normal)
		end
		local proposed_hang_position = self.HangPosition
		local proposed_normal = self.Normal
		local body_clear = not pose_changed or (midpoint_clear and self:_has_hang_body_clearance(self.HangPosition, self.Normal))
		if not body_clear then
			Traversal.restore_hang_pose(self, pose_snapshot)
		else
			if is_corner_transfer then
				self.CornerLockPosition = self.HangPosition
				self.CornerLockInputDirection = direction
			end
		end
		debug_log(self, "traverse", 0.5, "dir", direction,
			"source", climbable:GetFullName(),
			"sideHit", probe and probe.Instance:GetFullName(),
			"sideNormal", probe and probe.Normal,
			"topHit", top and top.Instance:GetFullName(),
			"topY", top and top.Position.Y,
			"nextSurface", next_climbable and next_climbable:GetFullName(),
			"sameHeight", same_height == true,
			"normalDot", horizontal_normal:Dot(normal),
			"corner", is_corner_transfer,
			"poseChanged", pose_changed,
			"bodyClear", body_clear,
			"midpointClear", midpoint_clear,
			"proposedPosition", proposed_hang_position,
			"finalPosition", self.HangPosition,
			"cornerLock", corner_locked)
	end

	self:_position_hanging()
end

return Traversal
