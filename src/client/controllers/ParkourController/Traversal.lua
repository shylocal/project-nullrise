local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Actions = require(ReplicatedStorage.shared.input.Actions)
local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(ReplicatedStorage.shared.config).Parkour
local State = require(script.Parent.State)
local Queries = require(script.Parent.Queries)

-- World up as a local value: selene's Roblox std types Vector3.yAxis as a
-- plain value without Vector3 methods.
local UP = Vector3.yAxis

local Traversal = {}

function Traversal.get_traverse_speed(self)
	local speed = Config.TraverseSpeed
	if self.Input:IsDown(Actions.Sprint) then
		speed *= Config.TraverseSprintMultiplier
	end
	return speed
end
function Traversal.snapshot_hang_pose(self)
	local hang = State.hang(self) or {}
	local root = self.Root
	return {
		CurrentClimbable = hang.CurrentClimbable,
		Normal = hang.Normal,
		HangDepthOffset = hang.HangDepthOffset,
		HangPosition = hang.HangPosition,
		CornerLockPosition = hang.CornerLockPosition,
		CornerLockInputDirection = hang.CornerLockInputDirection,
		CFrame = root and root.CFrame,
	}
end
function Traversal.restore_hang_pose(self, snapshot)
	if not snapshot or not snapshot.CurrentClimbable or not snapshot.Normal or not snapshot.HangPosition then
		return false
	end
	local hang = State.hang(self)
	if hang then
		-- Restore in place so callers holding the current record see the
		-- restored pose.
		hang.CurrentClimbable = snapshot.CurrentClimbable
		hang.Normal = snapshot.Normal
		hang.HangDepthOffset = snapshot.HangDepthOffset
		hang.HangPosition = snapshot.HangPosition
		hang.CornerLockPosition = snapshot.CornerLockPosition
		hang.CornerLockInputDirection = snapshot.CornerLockInputDirection
	elseif not State.enter(self, {
		kind = "Hanging",
		data = {
			CurrentClimbable = snapshot.CurrentClimbable,
			Normal = snapshot.Normal,
			HangDepthOffset = snapshot.HangDepthOffset,
			HangPosition = snapshot.HangPosition,
			CornerLockPosition = snapshot.CornerLockPosition,
			CornerLockInputDirection = snapshot.CornerLockInputDirection,
		},
	}) then
		return false
	end
	local root = self.Root
	if root and snapshot.CFrame then
		root.CFrame = snapshot.CFrame
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	return true
end
-- Confirm that a perpendicular corner face has a reachable top at the same
-- height whose guide covers the column the body moves into after turning, and
-- that the body fits there. Returns the corner transfer or nil.
local function validate_corner(self, candidate, normal, active_top_y)
	local root = self.Root
	local corner_probe = candidate.Probe
	local corner_normal = candidate.Normal
	local corner_top = Queries.cast_reachable_grab_top(self, 
		corner_probe.Position,
		corner_probe.Normal,
		root.Position,
		root.Position.Y + Config.HangDrop
	)
	local corner_guide = corner_top
		and (self.Climbables:GuideOf(corner_top.Instance) or corner_top.Instance)
	local corner_height_ok = corner_top
		and math.abs(corner_top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
		and corner_top.Normal.Y >= 0.5
	if not corner_top or not corner_guide or not corner_height_ok then
		return nil
	end

	-- The root is centered at the corner seam after a 90-degree turn, so its
	-- body can still overlap the old wall. Move one half-root-width along the
	-- old wall's outward axis, then confirm that the destination guide
	-- actually covers that landing column before accepting the corner.
	local corner_clearance = math.max(root.Size.X, root.Size.Z) * 0.5 + 0.1
	local cleared_sample = corner_top.Position + normal * corner_clearance
	local cleared_top = nil
	local cleared_distance = math.huge
	-- The exact clearance column can land on a part's inclusive edge. A tiny
	-- inward nudge avoids intermittent ray misses without weakening the
	-- requirement that the guide cover the intended landing column.
	local coverage_samples = {
		cleared_sample - normal * 0.2,
		cleared_sample,
		cleared_sample + normal * 0.2,
	}
	for _, coverage_sample in ipairs(coverage_samples) do
		for _, candidate_top in ipairs(Queries.get_guide_tops(self, corner_guide, coverage_sample)) do
			local distance = math.abs(candidate_top.Position.Y - active_top_y)
			local sample_distance = Vector.flatten(candidate_top.Position - cleared_sample).Magnitude
			if distance <= Config.TraverseHeightTolerance
				and sample_distance <= 1.25
				and distance < cleared_distance then
				cleared_top = candidate_top
				cleared_distance = distance
			end
		end
	end
	if not cleared_top then
		return nil
	end

	local candidate_hang = cleared_top.Position
		+ corner_normal * Config.WallGap
		- Vector3.new(0, Config.HangDrop, 0)
	if not Queries.has_hang_body_clearance(self, candidate_hang, corner_normal) then
		return nil
	end

	return {
		Top = cleared_top,
		Guide = corner_guide,
		Normal = corner_normal,
		WallInstance = corner_probe.Instance,
	}
end

-- Probe a fan of side rays for a perpendicular climbable face near the
-- character. Every candidate's score is known from its side ray alone, so
-- candidates are validated in score order and the first valid one wins; this
-- selects the same corner as validating every candidate, without paying for
-- the expensive top/coverage/clearance queries of lower-ranked candidates.
-- turn_normals is ordered by preference: the travel-side face scores at
-- least 100 lower than any opposite-side face, so the opposite side is only
-- probed when the travel side has no valid corner.
function Traversal.find_corner(self, turn_normals, candidate_position, normal, movement_tangent, active_top_y)
	local corner_longitudinal_offsets = {
		-normal * 1.8,
		-normal * 0.9,
		normal * 0.9,
		normal * 1.8,
	}

	for _, turn_normal in ipairs(turn_normals) do
		local turn_side_penalty = turn_normal:Dot(movement_tangent) >= 0 and 0 or 100
		local candidates = {}
		for order, longitudinal_offset in ipairs(corner_longitudinal_offsets) do
			local corner_origin = candidate_position
				+ Vector3.new(0, 1.5, 0)
				+ longitudinal_offset
				+ turn_normal * (Config.WallGap + 0.75)
			local corner_probe = Queries.cast_climbable_side(self, 
				corner_origin,
				-turn_normal * (Config.WallGap + Config.SurfaceProbe + 2)
			)
			local corner_normal = corner_probe and Vector.flatten(corner_probe.Normal)
			if corner_normal and corner_normal.Magnitude >= 0.05 then
				corner_normal = corner_normal.Unit
				local alignment_to_old = math.abs(corner_normal:Dot(normal))
				local alignment_to_turn = corner_normal:Dot(turn_normal)
				local along_movement = Vector.flatten(corner_probe.Position - candidate_position):Dot(movement_tangent)
				local perpendicular = alignment_to_old <= 0.45
					and alignment_to_turn >= 0.55
				local near_corner = along_movement >= -1.5
					and along_movement <= Config.WallGap + Config.SurfaceProbe + 1.5

				if perpendicular and near_corner then
					table.insert(candidates, {
						Probe = corner_probe,
						Normal = corner_normal,
						Order = order,
						Score = turn_side_penalty
							+ math.abs(along_movement)
							+ alignment_to_old * 2
							+ longitudinal_offset.Magnitude * 0.05,
					})
				end
			end
		end

		-- Equal scores keep probe order, matching a strict "<" best search.
		table.sort(candidates, function(a, b)
			if a.Score ~= b.Score then
				return a.Score < b.Score
			end
			return a.Order < b.Order
		end)
		for _, candidate in ipairs(candidates) do
			local corner = validate_corner(self, candidate, normal, active_top_y)
			if corner then
				return corner
			end
		end
	end

	return nil
end
-- Whether a recorded empty corner-fan result still describes the current
-- situation (same guide, direction and wall, and neither the hang target nor
-- the root moved past CornerProbeRecheckDistance). A blocked traversal reuses
-- it only within CornerProbeMissTtl.
function Traversal.can_reuse_corner_miss(miss, climbable, direction, normal, hang_position, root_position, straight_valid, now)
	return miss ~= nil
		and miss.Climbable == climbable
		and miss.Direction == direction
		and miss.Normal:Dot(normal) >= 0.999
		and (miss.HangPosition - hang_position).Magnitude < Config.CornerProbeRecheckDistance
		and (miss.RootPosition - root_position).Magnitude < Config.CornerProbeRecheckDistance
		and (straight_valid or now - miss.At < Config.CornerProbeMissTtl)
end

function Traversal.traverse(self, dt)
	local hang = State.hang(self)
	local root = self.Root
	local climbable = hang and hang.CurrentClimbable
	local normal = hang and hang.Normal
	if not root or not hang or not climbable or not normal or not climbable:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	-- Generic tall-wall catches are a one-way mantle interaction, not a
	-- tagged ledge route. W invokes the tall-wall mantle; A/D stays disabled.
	if not self.Climbables:IsClimbable(climbable) then
		self:_position_hanging(dt)
		return
	end

	local active_top_y = hang.HangPosition.Y + Config.HangDrop

	local direction = 0
	if self.Input:IsDown(Actions.Right) then
		direction += 1
	end
	if self.Input:IsDown(Actions.Left) then
		direction -= 1
	end

	if direction ~= 0 then
		local pose_snapshot = Traversal.snapshot_hang_pose(self)
		local tangent = Vector.flatten(root.CFrame.RightVector)
		if tangent.Magnitude < 0.05 then
			tangent = Vector.flatten(UP:Cross(normal))
		end
		if tangent.Magnitude < 0.05 then
			self:_position_hanging(dt)
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
			local center = cylinder.Position
			local radial = Vector.flatten(root.Position - center)
			if radial.Magnitude < 0.05 then
				radial = -Vector.flatten(normal)
			end
			if radial.Magnitude >= 0.05 then
				radial = radial.Unit
				local radius = math.max(cylinder.Size.Y, cylinder.Size.Z) * 0.5
				local arc = Traversal.get_traverse_speed(self) * math.max(dt, 0)
				local angular_tangent = Vector.flatten(UP:Cross(radial))
				local travel_tangent = tangent * direction
				local turn_sign = angular_tangent:Dot(travel_tangent) >= 0 and 1 or -1
				local angle = arc / math.max(radius + Config.WallGap, 0.1) * turn_sign
				local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(radial)
				local sample = center + rotated * radius
				local top = Queries.get_guide_top(self, climbable, sample)
				if top and top.Normal.Y >= 0.5 then
					local next_normal = Vector.flatten(sample - center)
					if next_normal.Magnitude >= 0.05 then
						next_normal = next_normal.Unit
						local next_position = Vector3.new(top.Position.X, hang.HangPosition.Y, top.Position.Z)
							+ next_normal * Config.WallGap
						local clear = Queries.has_hang_body_clearance(self, next_position, next_normal)
						if clear then
							hang.Normal = next_normal
							hang.HangDepthOffset = next_normal * Config.WallGap
							hang.HangPosition = next_position
						else
							Traversal.restore_hang_pose(self, pose_snapshot)
						end
					end
				end
			end
			self:_position_hanging(dt)
			return
		end

		-- During a smoothed W/S transfer, root.Position is intentionally between
		-- the source and destination heights. Lateral contact probes must use
		-- the logical hang target so they sample the destination ledge consistently.
		local candidate_position = hang.HangPosition
			+ tangent * direction * Traversal.get_traverse_speed(self) * math.max(dt, 0)
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = Queries.cast(self, 
			probe_origin,
			-normal * (Config.WallGap + Config.SurfaceProbe)
		)
		local top = probe
			and Queries.cast_reachable_grab_top(self, probe.Position, probe.Normal, candidate_position, active_top_y)
		local next_climbable = top
			and (self.Climbables:GuideOf(top.Instance) or top.Instance)
		local same_height = top
			and math.abs(top.Position.Y - active_top_y) <= Config.TraverseHeightTolerance
			and top.Normal.Y >= 0.5
		local horizontal_normal = probe and Vector.flatten(probe.Normal) or Vector3.zero

		-- Probe a wider corner fan when the character reaches a corner. Both
		-- handednesses are considered because a route may wrap around either
		-- a convex outside corner or a concave inside corner.
		local movement_tangent = tangent * direction
		local corner_locked = false
		if hang.CornerLockPosition then
			corner_locked = Vector.flatten(root.Position - hang.CornerLockPosition).Magnitude < Config.CornerLockDistance
			if hang.CornerLockInputDirection
				and direction ~= hang.CornerLockInputDirection then
				-- An intentional left/right reversal means the player wants to
				-- turn back now. Drop the seam lock immediately; same-direction
				-- movement remains locked until the character clears the corner.
				corner_locked = false
				hang.CornerLockPosition = nil
				hang.CornerLockInputDirection = nil
			elseif not corner_locked then
				hang.CornerLockPosition = nil
				hang.CornerLockInputDirection = nil
			end
		end
		local corner_turn_normals = {}
		if not corner_locked then
			-- The face facing the direction of travel is preferred. The opposite
			-- face remains a fallback for concave layouts, not an equal candidate.
			corner_turn_normals = { movement_tangent, -movement_tangent }
		end
		-- If neither the hang target nor the root has moved meaningfully since
		-- the fan last found nothing, the fan would repeat the same empty
		-- search. While straight traversal is valid, skip it until movement
		-- exceeds CornerProbeRecheckDistance; while traversal is blocked (the
		-- character cannot move), reuse the miss for CornerProbeMissTtl only.
		local straight_valid = top ~= nil and same_height
			and horizontal_normal.Magnitude >= 0.05
			and horizontal_normal.Unit:Dot(normal) >= 0.65
		local now = os.clock()
		if Traversal.can_reuse_corner_miss(self.CornerProbeMiss, climbable, direction, normal,
			hang.HangPosition, root.Position, straight_valid, now) then
			corner_turn_normals = {}
		end
		local probed_corners = #corner_turn_normals > 0
		local best_corner = Traversal.find_corner(
			self,
			corner_turn_normals,
			candidate_position,
			normal,
			movement_tangent,
			active_top_y
		)
		if best_corner then
			self.CornerProbeMiss = nil
		elseif probed_corners then
			self.CornerProbeMiss = {
				Climbable = climbable,
				Direction = direction,
				Normal = normal,
				HangPosition = hang.HangPosition,
				RootPosition = root.Position,
				At = now,
			}
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
			hang.Normal = horizontal_normal
			hang.HangDepthOffset = horizontal_normal * Config.WallGap
			hang.HangPosition = Vector3.new(
				top.Position.X,
				hang.HangPosition.Y,
				top.Position.Z
			) + hang.HangDepthOffset
		elseif top and next_climbable and next_climbable ~= climbable and same_height
			and (is_corner_transfer or probe_normal_aligned) then
			hang.CurrentClimbable = next_climbable
			hang.Normal = horizontal_normal
			hang.HangDepthOffset = horizontal_normal * Config.WallGap
			hang.HangPosition = Vector3.new(
				top.Position.X,
				hang.HangPosition.Y,
				top.Position.Z
			) + hang.HangDepthOffset
		end

		-- Exempt only the exact wall part supporting the hang; the top is below the root by Config.HangDrop and must not mask a thick-wall collision.
		local pose_changed = (hang.HangPosition - pose_snapshot.HangPosition).Magnitude > 1e-3
			or hang.Normal:Dot(pose_snapshot.Normal) < 0.999
		local midpoint_clear = true
		if is_corner_transfer and hang.Normal:Dot(pose_snapshot.Normal) < 0.707 then
			local midpoint = pose_snapshot.HangPosition:Lerp(hang.HangPosition, 0.5)
			local midpoint_normal = Vector.flatten(pose_snapshot.Normal + hang.Normal)
			if midpoint_normal.Magnitude < 0.05 then
				midpoint_normal = hang.Normal
			end
			midpoint_clear = Queries.has_hang_body_clearance(self, midpoint, midpoint_normal)
		end
		local body_clear = not pose_changed or (midpoint_clear and Queries.has_hang_body_clearance(self, hang.HangPosition, hang.Normal))
		if not body_clear then
			Traversal.restore_hang_pose(self, pose_snapshot)
		elseif is_corner_transfer then
			hang.CornerLockPosition = hang.HangPosition
			hang.CornerLockInputDirection = direction
		end
	end

	self:_position_hanging(dt)
end

return Traversal
