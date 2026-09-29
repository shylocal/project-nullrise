local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local ParkourController = {}
ParkourController.__index = ParkourController

-- Keep verbose parkour diagnostics off during normal play; re-enable only when debugging.
local DEBUG_PARKOUR = false

local CLIMBABLE_TAG = "Climbable"
local WALL_REACH = 3.25
local MAX_GRAB_HEIGHT = 4.5
local HANG_DROP = 2.35
local WALL_GAP = 0.8
local TRAVERSE_SPEED = 5
local SURFACE_PROBE = 1.4
local MAX_TOP_SURFACE_HITS = 16
-- Max ledge-to-ledge rise; root-to-top range also accounts for the hang drop below the ledge.
local MANTLE_MAX_RISE = 12.5
local MANTLE_MAX_INWARD = 8
local MANTLE_MAX_OUTWARD = 2
local MANTLE_MAX_LATERAL = 5
local MANTLE_MIN_RISE = 0.25
local TRAVERSE_HEIGHT_TOLERANCE = 1.5

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

function ParkourController.new(character, input_controller, movement_controller)
	local self = setmetatable({
		Character = character,
		InputController = input_controller,
		MovementController = movement_controller,
		Trove = Trove.new(),
		State = "Grounded",
		Humanoid = character:FindFirstChildOfClass("Humanoid"),
		Root = character:FindFirstChild("HumanoidRootPart"),
		CurrentClimbable = nil,
		Normal = nil,
		HangDepthOffset = nil,
		HangPosition = nil,
		AutoRotateBeforeHang = nil,
		PlatformStandBeforeHang = nil,
		GrabBlockedUntilJumpReleased = false,
		LastDetectionReason = nil,
		LastDetectionLogAt = 0,
		LastTraversalDiagnostic = nil,
		LastTraversalSuccessLogAt = 0,
	}, ParkourController)

	self:_start()
	return self
end

function ParkourController:_debug(message, ...)
	if not DEBUG_PARKOUR then return end
	print("[Parkour] " .. string.format(message, ...))
end

function ParkourController:_debug_detection(reason, ...)
	local now = os.clock()
	if self.LastDetectionReason == reason and now - self.LastDetectionLogAt < 1 then
		return
	end
	self.LastDetectionReason = reason
	self.LastDetectionLogAt = now
	self:_debug("detect_surface: " .. reason, ...)
end

function ParkourController:_debug_traversal(reason, ...)
	if self.LastTraversalDiagnostic == reason then return end
	self.LastTraversalDiagnostic = reason
	self:_debug("traversal: " .. reason, ...)
end

function ParkourController:_start()
	self:_debug("controller initialized; root=%s humanoid=%s", tostring(self.Root ~= nil), tostring(self.Humanoid ~= nil))
	self.Trove:Connect(self.InputController.ActionBegan, function(action)
		self:_debug("input began: %s (state=%s)", tostring(action), self.State)
		if action == Actions.Jump then
			self:_on_jump()
		elseif action == Actions.Forward and self.State == "Hanging" then
			self:_try_mantle()
		elseif action == Actions.Backward and self.State == "Hanging" then
			self:_try_lower_ledge()
		end
	end)

	self.Trove:Connect(self.InputController.ActionEnded, function(action)
		self:_debug("input ended: %s (state=%s)", tostring(action), self.State)
		if action == Actions.Jump then
			if self.GrabBlockedUntilJumpReleased then
				self.GrabBlockedUntilJumpReleased = false
				self:_debug("Space released; ledge grabbing re-armed")
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
		self:_debug("character child added: %s (%s)", child.Name, child.ClassName)
		if child.Name == "HumanoidRootPart" then
			self.Root = child
			self:_debug("root part bound: %s", child:GetFullName())
		elseif child:IsA("Humanoid") then
			self:_bind_humanoid(child)
		end
	end)
end

function ParkourController:_bind_character_parts()
	self.Root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")
	self:_debug("character parts discovered; root=%s humanoid=%s", tostring(self.Root ~= nil), tostring(humanoid ~= nil))
	if humanoid then self:_bind_humanoid(humanoid) end
end

function ParkourController:_bind_humanoid(humanoid)
	if self.Humanoid == humanoid then return end
	self.Humanoid = humanoid
	self:_debug("humanoid bound: %s", humanoid:GetFullName())
	self.Trove:Connect(humanoid.Died, function()
		self:_release()
	end)
end

function ParkourController:_cast(origin, direction, respect_can_collide)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = respect_can_collide == true
	return Workspace:Raycast(origin, direction, params)
end

function ParkourController:_get_climbable_guide(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, CLIMBABLE_TAG) then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ParkourController:_is_climbable(instance)
	return self:_get_climbable_guide(instance) ~= nil
end

function ParkourController:_cast_reachable_grab_top(wall_position, wall_normal, root_position)
	-- Several climb guides can overlap vertically. A single downward ray hits
	-- the highest one first, even when that ledge is outside grab range. Walk
	-- down through successive hits and choose the climbable, walkable top closest
	-- in height to the character.
	local standing_height = self:_standing_height()
	local origin = Vector3.new(
		wall_position.X,
		root_position.Y + MAX_GRAB_HEIGHT + standing_height + 2,
		wall_position.Z
	) - wall_normal * 0.1
	local direction = Vector3.new(
		0,
		-(MAX_GRAB_HEIGHT * 2 + standing_height + 4),
		0
	)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local exclusions = { self.Character }
	local best = nil
	local best_height_distance = math.huge
	for hit_index = 1, MAX_TOP_SURFACE_HITS do
		params.FilterDescendantsInstances = exclusions
		local candidate = Workspace:Raycast(origin, direction, params)
		if not candidate then
			break
		end

		local height_delta = root_position.Y - candidate.Position.Y
		local height_distance = math.abs(height_delta)
		local climbable = self:_is_climbable(candidate.Instance)
		local walkable = candidate.Normal.Y >= 0.5
		local reachable = height_delta >= -MAX_GRAB_HEIGHT
			and height_delta <= MAX_GRAB_HEIGHT

		if climbable and walkable and reachable and height_distance < best_height_distance then
			best = candidate
			best_height_distance = height_distance
		else
			self:_debug_detection(
				"grab top scan skipped hit %d: %s climbable=%s walkable=%s height_delta=%.2f",
				hit_index,
				candidate.Instance:GetFullName(),
				tostring(climbable),
				tostring(walkable),
				height_delta
			)
		end

		table.insert(exclusions, candidate.Instance)
	end

	if best then
		self:_debug_detection(
			"grab top scan selected %s at height_delta=%.2f (searched %d hits)",
			best.Instance:GetFullName(),
			root_position.Y - best.Position.Y,
			#exclusions - 1
		)
	else
		self:_debug_detection("grab top scan found no reachable tagged top (searched %d hits)", #exclusions - 1)
	end
	return best
end

function ParkourController:_detect_surface()
	local root = self.Root
	if not root then
		self:_debug_detection("root missing")
		return nil
	end

	local direction = flatten(root.CFrame.LookVector)
	if direction.Magnitude < 0.1 then
		self:_debug_detection("look direction too small")
		return nil
	end
	direction = direction.Unit

	local origin = root.Position + Vector3.new(0, 1.1, 0)
	local wall = self:_cast(origin, direction * WALL_REACH)
	if not wall then
		self:_debug_detection("wall ray missed")
		return nil
	end
	if not self:_is_climbable(wall.Instance) then
		self:_debug_detection("wall hit %s (not climbable)", wall.Instance:GetFullName())
		return nil
	end

	local top = self:_cast_reachable_grab_top(wall.Position, wall.Normal, root.Position)
	if not top then
		self:_debug_detection("top ray missed; wall=%s", wall.Instance:GetFullName())
		return nil
	end
	if not self:_is_climbable(top.Instance) then
		self:_debug_detection("top hit %s (not climbable)", top.Instance:GetFullName())
		return nil
	end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -MAX_GRAB_HEIGHT or height_delta > MAX_GRAB_HEIGHT then
		self:_debug_detection("height out of range; delta=%.2f max=%.2f", height_delta, MAX_GRAB_HEIGHT)
		return nil
	end

	local hang_normal = flatten(wall.Normal)
	if hang_normal.Magnitude < 0.05 then
		self:_debug_detection("wall normal has no horizontal component; wall=%s", wall.Instance:GetFullName())
		return nil
	end
	hang_normal = hang_normal.Unit
	local hang_position = top.Position + hang_normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
	local body_clearance = self:_cast(
		hang_position + Vector3.new(0, 0.8, 0),
		-hang_normal * 0.35
	)
	if body_clearance and not self:_is_climbable(body_clearance.Instance) then
		self:_debug_detection("clearance blocked by %s (not climbable)", body_clearance.Instance:GetFullName())
		return nil
	end

	self:_debug_detection(
		"candidate accepted; wall=%s top=%s height_delta=%.2f",
		wall.Instance:GetFullName(),
		top.Instance:GetFullName(),
		height_delta
	)
	return self:_get_climbable_guide(top.Instance), hang_normal, hang_position
end

function ParkourController:_grab(guide, normal, position)
	if self.State ~= "Grounded" or not guide then return end
	self:_debug("grabbed; guide=%s position=%s", guide:GetFullName(), tostring(position))
	self.State = "Hanging"
	self.CurrentClimbable = guide
	self.Normal = normal
	self.HangDepthOffset = flatten(normal).Unit * WALL_GAP
	self.HangPosition = position

	local humanoid = self.Humanoid
	if humanoid then
		self.AutoRotateBeforeHang = humanoid.AutoRotate
		self.PlatformStandBeforeHang = humanoid.PlatformStand
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
	end

	self.MovementController:SetSprintBlocked(true)
	self:_position_hanging()
end

function ParkourController:_position_hanging()
	local root = self.Root
	local position = self.HangPosition
	local normal = self.Normal
	if not root or not position or not normal then return end

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = CFrame.lookAt(position, position - normal)
end

function ParkourController:_step(dt)
	if self.State == "Grounded" then
		if self.InputController:IsDown(Actions.Jump) and not self.GrabBlockedUntilJumpReleased then
			local climbable, normal, position = self:_detect_surface()
			if climbable then self:_grab(climbable, normal, position) end
		end
	elseif self.State == "Hanging" then
		self:_traverse(dt)
	end
end

function ParkourController:_traverse(dt)
	local root = self.Root
	local climbable = self.CurrentClimbable
	local normal = self.Normal
	if not root or not climbable or not normal or not climbable:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	local active_top = self:_get_guide_top(climbable)
	if not active_top then
		self:_release()
		return
	end

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		local tangent = flatten(root.CFrame.RightVector)
		if tangent.Magnitude < 0.05 then
			tangent = flatten(Vector3.yAxis:Cross(normal))
		end
		if tangent.Magnitude < 0.05 then
			self:_position_hanging()
			return
		end
		tangent = tangent.Unit

		local candidate_position = root.Position
			+ tangent * direction * TRAVERSE_SPEED * math.max(dt, 0)
		-- Re-sample locally every step so traversal can follow curved guides
		-- (especially cylinders) instead of moving along a stale tangent.
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = self:_cast(
			probe_origin,
			-normal * (WALL_GAP + SURFACE_PROBE)
		)
		local top = probe
			and self:_cast_reachable_grab_top(probe.Position, probe.Normal, root.Position)
		local next_climbable = top
			and self:_get_climbable_guide(top.Instance)
		local same_height = top
			and math.abs(top.Position.Y - active_top.Position.Y) <= TRAVERSE_HEIGHT_TOLERANCE
			and top.Normal.Y >= 0.5
		local horizontal_normal = probe and flatten(probe.Normal) or Vector3.zero
		if horizontal_normal.Magnitude >= 0.05 then
			horizontal_normal = horizontal_normal.Unit
		else
			horizontal_normal = normal
		end

		if top and next_climbable == climbable and same_height then
			-- Keep the cache on the active guide, but refresh the contact normal
			-- from the local hit so round surfaces can turn beneath the player.
			-- Preserve the current root height to prevent per-step vertical drift.
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * WALL_GAP
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		elseif top and next_climbable and next_climbable ~= climbable and same_height then
			-- Switch the cache only after the local probe confirms a distinct,
			-- adjacent tagged guide at the same height.
			self.CurrentClimbable = next_climbable
			self.Normal = horizontal_normal
			self.HangDepthOffset = horizontal_normal * WALL_GAP
			self.HangPosition = Vector3.new(
				top.Position.X,
				self.HangPosition.Y,
				top.Position.Z
			) + self.HangDepthOffset
		else
			-- Invalid or missing support stops movement at the last valid hang
			-- transform rather than drifting down or snapping to a guide center.
			self:_debug_traversal("local surface probe did not validate the active guide")
		end
	end

	self:_position_hanging()
end

function ParkourController:_on_jump()
	self:_debug("jump pressed; state=%s", self.State)
	if self.State == "Hanging" then
		return
	end
	if self.GrabBlockedUntilJumpReleased then
		self:_debug("jump grab ignored; waiting for Space release after mantle")
		return
	end

	if self.State == "Grounded" then
		local climbable, normal, position = self:_detect_surface()
		if climbable then self:_grab(climbable, normal, position) end
	end
end

function ParkourController:_try_lower_ledge()
	self:_debug("lower ledge requested; state=%s", self.State)
	if self.State ~= "Hanging" or not self.Root or not self.HangPosition or not self.Normal then
		self:_debug("lower ledge aborted; missing hanging state or character parts")
		return
	end

	local root = self.Root
	local normal = flatten(self.Normal)
	if normal.Magnitude < 0.05 then
		self:_debug("lower ledge aborted; active wall normal is invalid")
		return
	end
	normal = normal.Unit
	local tangent = flatten(root.CFrame.RightVector)
	if tangent.Magnitude < 0.05 then
		tangent = flatten(Vector3.yAxis:Cross(normal))
	end
	if tangent.Magnitude < 0.05 then
		self:_debug("lower ledge aborted; lateral axis is invalid")
		return
	end
	tangent = tangent.Unit

	local current_top = self.HangPosition - normal * WALL_GAP + Vector3.new(0, HANG_DROP, 0)
	local best_top = nil
	local best_drop = math.huge
	local best_distance = math.huge
	local best_lateral_offset = 0
	local examined = 0

	-- Search tagged guides directly instead of relying on a downward ray that
	-- can be occluded by the active guide and incorrectly fall through to ground.
	-- S selects the closest lower reachable ledge and keeps the hang state.
	for _, guide in ipairs(CollectionService:GetTagged(CLIMBABLE_TAG)) do
		if guide ~= self.CurrentClimbable and guide:IsDescendantOf(Workspace) then
			local top = self:_get_guide_top(guide)
			if top and top.Normal.Y >= 0.5 then
				local relative = top.Position - current_top
				local drop = current_top.Y - top.Position.Y
				local inward = relative:Dot(-normal)
				local guide_center_lateral = flatten(relative):Dot(tangent)
				local guide_half_extent = self:_get_guide_half_extent(top, tangent)
				local lateral_gap = math.max(0, math.abs(guide_center_lateral) - guide_half_extent)
				local lateral_margin = math.max(root.Size.X * 0.5, 0.5)
				local safe_lateral_extent = math.max(0, guide_half_extent - lateral_margin)
				local player_lateral = flatten(root.Position - current_top):Dot(tangent)
				local target_lateral_offset = math.clamp(
					player_lateral - guide_center_lateral,
					-safe_lateral_extent,
					safe_lateral_extent
				)
				local in_vertical_range = drop >= 0.5 and drop <= MANTLE_MAX_RISE
				local in_reach = inward >= -MANTLE_MAX_OUTWARD
					and inward <= MANTLE_MAX_INWARD
					and lateral_gap <= MANTLE_MAX_LATERAL

				if in_vertical_range and in_reach then
					examined += 1
					local target_top_position = top.Position + tangent * target_lateral_offset
					local horizontal_distance = flatten(target_top_position - current_top).Magnitude
					if drop < best_drop
						or (drop == best_drop and horizontal_distance < best_distance) then
						best_top = top
						best_drop = drop
						best_distance = horizontal_distance
						best_lateral_offset = target_lateral_offset
					end
				end
			end
		end
	end

	if not best_top then
		-- S is strictly a lower-ledge transfer. Stay on the current guide
		-- when no tagged lower ledge is reachable; never snap to the ground.
		self:_debug("lower ledge: no eligible tagged guide found; remaining on current ledge")
		return
	end

	-- Re-sample at the player's intended landing column so the hang height
	-- follows the actual top surface instead of the guide's center sample.
	local target_sample = best_top.Position + tangent * best_lateral_offset
	best_top = self:_get_guide_top(best_top.Guide, target_sample) or best_top
	local target_normal = self:_get_guide_wall_normal(best_top.Guide, best_top, normal)
	self:_debug(
		"lower ledge selected; guide=%s drop=%.2f horizontal_distance=%.2f examined=%d",
		best_top.Guide:GetFullName(),
		best_drop,
		best_distance,
		examined
	)
	self:_transfer_hang_to_ledge(best_top, target_normal)

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

function ParkourController:_get_guide_half_extent(top, tangent)
	local guide = top.Guide
	if guide and guide:IsA("BasePart") and guide.Shape == Enum.PartType.Cylinder then
		-- Roblox cylinders run along their local X axis. Project that axis and
		-- its circular cross-section separately instead of treating the shape
		-- as a rectangular X/Z footprint.
		local axis = guide.CFrame.RightVector
		local axial_projection = math.clamp(math.abs(tangent:Dot(axis)), 0, 1)
		local radius = math.max(guide.Size.Y, guide.Size.Z) * 0.5
		return axial_projection * guide.Size.X * 0.5
			+ math.sqrt(math.max(0, 1 - axial_projection * axial_projection)) * radius
	end

	-- Project a guide's horizontal bounding box onto the character's
	-- sideways axis so a long rectangular guide remains traversable off-center.
	local right = flatten(top.BoxCFrame.RightVector)
	local look = flatten(top.BoxCFrame.LookVector)
	return math.abs(tangent:Dot(right)) * top.BoxSize.X * 0.5
		+ math.abs(tangent:Dot(look)) * top.BoxSize.Z * 0.5
end

function ParkourController:_get_guide_wall_normal(guide, top, preferred_normal)
	local preferred = flatten(preferred_normal)
	if preferred.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	preferred = preferred.Unit

	-- Probe the destination guide at the height of the hanging torso. This
	-- obtains its own outward-facing side normal instead of reusing the
	-- previous ledge's normal, which can push the head into an offset ledge.
	local sample_drop = math.max(0.35, HANG_DROP - 1.1)
	local origin = top.Position
		- Vector3.new(0, sample_drop, 0)
		+ preferred * (WALL_GAP + SURFACE_PROBE + 0.5)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { guide }
	params.IgnoreWater = true
	params.RespectCanCollide = false
	local hit = Workspace:Raycast(
		origin,
		-preferred * (WALL_GAP + SURFACE_PROBE + 1),
		params
	)
	if hit then
		local side_normal = flatten(hit.Normal)
		if side_normal.Magnitude >= 0.05 then
			side_normal = side_normal.Unit
			if side_normal:Dot(preferred) < 0 then
				side_normal = -side_normal
			end
			return side_normal
		end
	end

	return preferred
end

function ParkourController:_get_hang_position_for_top(top, normal)
	-- The caller samples top.Position at the intended landing column.
	-- Do not apply a tangent offset here as well: doing so double-counts the
	-- lateral adjustment and causes drift on repeated up/down transitions.
	return top.Position
		+ normal * WALL_GAP
		- Vector3.new(0, HANG_DROP, 0)
end

function ParkourController:_transfer_hang_to_ledge(top, normal)
	local root = self.Root
	if not root or not top or not normal then return false end

	-- Keep the established scalar wall clearance, but orient its vector along
	-- the destination face. Reusing the old world-space vector while changing
	-- LookVector can rotate the body into a ledge when the sampled normals
	-- differ slightly, even when both ledges have the same actual depth.
	local depth = self.HangDepthOffset and self.HangDepthOffset.Magnitude or WALL_GAP
	if depth < 0.05 then
		depth = WALL_GAP
	end
	local target_normal = flatten(normal)
	if target_normal.Magnitude < 0.05 then
		target_normal = flatten(self.Normal or Vector3.zAxis)
	end
	if target_normal.Magnitude < 0.05 then
		target_normal = Vector3.zAxis
	else
		target_normal = target_normal.Unit
	end
	local depth_offset = target_normal * depth
	local hang_position = top.Position
		+ depth_offset
		- Vector3.new(0, HANG_DROP, 0)
	self.State = "Hanging"
	self.CurrentClimbable = top.Guide or self:_get_climbable_guide(top.Instance)
	self.Normal = target_normal
	self.HangDepthOffset = depth_offset
	self.HangPosition = hang_position

	-- Keep the existing hang lock and movement restriction; do not release
	-- the character or make the non-collidable guide physically solid.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	self:_position_hanging()
	self:_debug(
		"hang transferred; guide=%s hang=%s state=%s",
		top.Instance:GetFullName(),
		tostring(hang_position),
		self.State
	)
	return true
end

function ParkourController:_get_guide_top(guide, sample_position)
	local box_cframe
	local box_size
	local hit_instance
	if guide:IsA("BasePart") then
		box_cframe = guide.CFrame
		box_size = guide.Size
		hit_instance = guide
	elseif guide:IsA("Model") then
		box_cframe, box_size = guide:GetBoundingBox()
		hit_instance = guide.PrimaryPart or guide:FindFirstChildWhichIsA("BasePart", true)
	else
		return nil
	end
	if not hit_instance then return nil end

	-- Sample the actual highest walkable surface at the guide's horizontal
	-- center. This handles cylinders whose long axis is local X, including
	-- cylinders rotated upright, without assuming local Y is their top.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { guide }
	params.IgnoreWater = true
	params.RespectCanCollide = false
	local ray_length = box_size.Magnitude * 2 + 8
	local ray_origin = Vector3.new(
		sample_position and sample_position.X or box_cframe.Position.X,
		box_cframe.Position.Y + box_size.Magnitude + 4,
		sample_position and sample_position.Z or box_cframe.Position.Z
	)
	local sampled_top = Workspace:Raycast(
		ray_origin,
		Vector3.new(0, -ray_length, 0),
		params
	)
	if sampled_top and sampled_top.Normal.Y >= 0.5 then
		return {
			Instance = sampled_top.Instance,
			Guide = guide,
			Position = sampled_top.Position,
			Normal = sampled_top.Normal,
			BoxCFrame = box_cframe,
			BoxSize = box_size,
		}
	end

	-- Retain the oriented-box fallback for guides whose center is hollow or
	-- whose top cannot be sampled, but only when the box's own up axis is
	-- sufficiently walkable.
	local up = box_cframe.UpVector
	if up.Y < 0.5 then
		return nil
	end

	return {
		Instance = hit_instance,
		Guide = guide,
		Position = box_cframe.Position + up * (box_size.Y * 0.5),
		Normal = up,
		BoxCFrame = box_cframe,
		BoxSize = box_size,
	}
end

function ParkourController:_try_mantle()
	self:_debug("mantle requested; state=%s", self.State)
	if self.State ~= "Hanging" or not self.Root or not self.CurrentClimbable
		or not self.HangPosition or not self.Normal
		or not self.CurrentClimbable:IsDescendantOf(Workspace) then
		self:_debug("mantle aborted; missing active guide or character parts")
		return
	end

	local root = self.Root
	local normal = self.Normal
	local current_top = self.HangPosition
		- normal * WALL_GAP
		+ Vector3.new(0, HANG_DROP, 0)
	local tangent = flatten(root.CFrame.RightVector)
	if tangent.Magnitude > 0.05 then
		tangent = tangent.Unit
	else
		tangent = flatten(Vector3.yAxis:Cross(normal)).Unit
	end

	local best_top = nil
	-- Prefer the nearest higher ledge so stacked guide blocks are climbed
	-- one at a time instead of teleporting to the highest reachable guide.
	local best_height = math.huge
	local best_distance = math.huge
	local best_lateral_offset = 0
	local considered = 0
	local rejected = 0

	-- Tagged guide tops define the ledges directly. W moves the character's
	-- hang point to the next higher guide without requiring floor support.
	for _, guide in ipairs(CollectionService:GetTagged(CLIMBABLE_TAG)) do
		if guide:IsDescendantOf(Workspace) then
			local top = self:_get_guide_top(guide)
			if top then
				local relative = top.Position - current_top
				local inward = relative:Dot(-normal)
				local player_lateral = flatten(root.Position - current_top):Dot(tangent)
				local guide_center_lateral = flatten(relative):Dot(tangent)
				local guide_half_extent = self:_get_guide_half_extent(top, tangent)
				-- Only the distance beyond the guide's lateral footprint counts
				-- against reach; being far from its center is fine when still over it.
				local lateral = math.max(
					0,
					math.abs(player_lateral - guide_center_lateral) - guide_half_extent
				)
				local lateral_margin = math.max(root.Size.X * 0.5, 0.5)
				local safe_lateral_extent = math.max(0, guide_half_extent - lateral_margin)
				local target_lateral_offset = math.clamp(
					player_lateral - guide_center_lateral,
					-safe_lateral_extent,
					safe_lateral_extent
				)
				local rise = top.Position.Y - current_top.Y
				local root_height_delta = root.Position.Y - top.Position.Y
				local in_vertical_range = rise > MANTLE_MIN_RISE
					and rise <= MANTLE_MAX_RISE
					and root_height_delta >= -(MANTLE_MAX_RISE + HANG_DROP)
					and root_height_delta <= MAX_GRAB_HEIGHT
				local in_reach = inward >= -MANTLE_MAX_OUTWARD
					and inward <= MANTLE_MAX_INWARD
					and lateral <= MANTLE_MAX_LATERAL

				if in_vertical_range and in_reach and top.Normal.Y >= 0.5 then
					considered += 1
					local hang_position = top.Position
						+ tangent * target_lateral_offset
						+ normal * WALL_GAP
						- Vector3.new(0, HANG_DROP, 0)
					local target_top_position = top.Position + tangent * target_lateral_offset
					local horizontal_distance = flatten(target_top_position - current_top).Magnitude
					if rise < best_height
						or (rise == best_height and horizontal_distance < best_distance) then
						best_top = top
						best_height = rise
						best_distance = horizontal_distance
						best_lateral_offset = target_lateral_offset
						self:_debug(
							"mantle guide candidate; guide=%s rise=%.2f inward=%.2f lateral=%.2f hang=%s",
							guide:GetFullName(),
							rise,
							inward,
							lateral,
							tostring(hang_position)
						)
					end
				else
					rejected += 1
					self:_debug(
						"mantle guide skipped; guide=%s rise=%.2f root_delta=%.2f inward=%.2f lateral=%.2f vertical_ok=%s reach_ok=%s top_normal=%s",
						guide:GetFullName(),
						rise,
						root_height_delta,
						inward,
						lateral,
						tostring(in_vertical_range),
						tostring(in_reach),
						tostring(top.Normal)
					)
				end
			end
		end
	end

	if best_top then
		self:_debug(
			"mantle guide selected; guide=%s rise=%.2f horizontal_distance=%.2f considered=%d rejected=%d",
			best_top.Instance:GetFullName(),
			best_height,
			best_distance,
			considered,
			rejected
		)
		-- Match the top sample to the character's target column to avoid a
		-- small vertical mismatch when moving onto an offset or curved ledge.
		local target_sample = best_top.Position + tangent * best_lateral_offset
		best_top = self:_get_guide_top(best_top.Guide, target_sample) or best_top
		local target_normal = self:_get_guide_wall_normal(best_top.Guide, best_top, normal)
		self:_transfer_hang_to_ledge(best_top, target_normal)
	else
		self:_debug(
			"mantle found no reachable higher guide; tagged_guides=%d considered=%d rejected=%d max_rise=%.2f",
			#CollectionService:GetTagged(CLIMBABLE_TAG),
			considered,
			rejected,
			MANTLE_MAX_RISE
		)
	end
end

function ParkourController:_release()
	if self.State ~= "Hanging" then
		self:_debug("release ignored; state=%s", self.State)
		return
	end
	self:_debug("released from hanging; Space release or controller cleanup")
	self.State = "Grounded"
	self.CurrentClimbable = nil
	self.Normal = nil
	self.HangDepthOffset = nil
	self.HangPosition = nil

	local humanoid = self.Humanoid
	if humanoid then
		humanoid.AutoRotate = self.AutoRotateBeforeHang
		humanoid.PlatformStand = self.PlatformStandBeforeHang
	end
	self.AutoRotateBeforeHang = nil
	self.PlatformStandBeforeHang = nil
	if self.MovementController then
		self.MovementController:SetSprintBlocked(false)
	end
end

function ParkourController:Destroy()
	self:_release()
	self.Trove:Destroy()
end

return ParkourController
