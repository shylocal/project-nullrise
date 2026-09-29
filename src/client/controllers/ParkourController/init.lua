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
local LOWER_PROBE_OFFSETS = { 0.15, 0.45, 0.75, 1.05 }
local MAX_TOP_SURFACE_HITS = 16
-- Max ledge-to-ledge rise; root-to-top range also accounts for the hang drop below the ledge.
local MANTLE_MAX_RISE = 12.5
local MANTLE_MAX_INWARD = 8
local MANTLE_MAX_OUTWARD = 2
local MANTLE_MAX_LATERAL = 5
local MANTLE_MIN_RISE = 0.25
local TRAVERSE_HEIGHT_TOLERANCE = 1.5
local MAX_GROUND_DROP = 32

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
		Surface = nil,
		Normal = nil,
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

function ParkourController:_is_climbable(instance)
	local current = instance
	while current and current ~= Workspace do
		if CollectionService:HasTag(current, CLIMBABLE_TAG) then
			return true
		end
		current = current.Parent
	end
	return false
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

	local hang_position = top.Position + wall.Normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
	local body_clearance = self:_cast(
		hang_position + Vector3.new(0, 0.8, 0),
		-wall.Normal * 0.35
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
	return wall.Instance, wall.Normal, hang_position
end

function ParkourController:_grab(surface, normal, position)
	if self.State ~= "Grounded" then return end
	self:_debug("grabbed; surface=%s position=%s", surface:GetFullName(), tostring(position))
	self.State = "Hanging"
	self.Surface = surface
	self.Normal = normal
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
			local surface, normal, position = self:_detect_surface()
			if surface then self:_grab(surface, normal, position) end
		end
	elseif self.State == "Hanging" then
		self:_traverse(dt)
	end
end

function ParkourController:_traverse(dt)
	local root = self.Root
	local surface = self.Surface
	local normal = self.Normal
	if not root or not surface or not normal or not surface:IsDescendantOf(Workspace) then
		self:_release()
		return
	end

	local direction = 0
	if self.InputController:IsDown(Actions.Right) then direction += 1 end
	if self.InputController:IsDown(Actions.Left) then direction -= 1 end

	if direction ~= 0 then
		-- Use the character's local right vector so A/D always match the
		-- direction the character is facing, then re-sample the surface each
		-- frame to follow curved walls instead of a fixed world-space axis.
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
		local probe_origin = candidate_position
			+ Vector3.new(0, 1.5, 0)
			+ normal * 0.3
		local probe = self:_cast(
			probe_origin,
			-normal * (WALL_GAP + SURFACE_PROBE)
		)

		-- The side probe can hit an untagged backing wall. Treat it only as
		-- a geometric guide; the ledge's top surface is the climbability check.
		if not probe then
			self:_debug_traversal("side probe missed")
		else
			local top = self:_cast_reachable_grab_top(probe.Position, probe.Normal, root.Position)
			if not top then
				self:_debug_traversal("side hit %s; top ray missed", probe.Instance:GetFullName())
			elseif not self:_is_climbable(top.Instance) then
				self:_debug_traversal(
					"side hit %s; top hit %s (not climbable)",
					probe.Instance:GetFullName(),
					top.Instance:GetFullName()
				)
			else
				local height_delta = root.Position.Y - top.Position.Y
				if height_delta >= -MAX_GRAB_HEIGHT and height_delta <= MAX_GRAB_HEIGHT then
					self.LastTraversalDiagnostic = nil
					self.Surface = probe.Instance
					self.Normal = probe.Normal
					self.HangPosition = top.Position
						+ probe.Normal * WALL_GAP
						- Vector3.new(0, HANG_DROP, 0)
					local now = os.clock()
					if now - self.LastTraversalSuccessLogAt >= 0.75 then
						self:_debug(
							"traversal progressing %s; side_hit=%s top=%s hang=%s",
							direction > 0 and "right" or "left",
							probe.Instance:GetFullName(),
							top.Instance:GetFullName(),
							tostring(self.HangPosition)
						)
						self.LastTraversalSuccessLogAt = now
					end
				else
					self:_debug_traversal("top hit %s; height_delta=%.2f out of range", top.Instance:GetFullName(), height_delta)
				end
			end
		end
	end

	-- If the probe reaches the end of a ledge or finds an invalid surface,
	-- keep the last valid hang transform rather than dropping unexpectedly.
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
		local surface, normal, position = self:_detect_surface()
		if surface then self:_grab(surface, normal, position) end
	end
end

function ParkourController:_try_lower_ledge()
	self:_debug("lower ledge requested; state=%s", self.State)
	if self.State ~= "Hanging" or not self.Root or not self.HangPosition or not self.Normal then
		self:_debug("lower ledge aborted; missing hanging state or character parts")
		return
	end

	-- Sample several points just beyond the wall face. The old single probe
	-- sat a full character gap in front of the ledge and could miss narrow
	-- lower platforms or fall clear of the platform's footprint.
	local current_top = self.HangPosition - self.Normal * WALL_GAP + Vector3.new(0, HANG_DROP, 0)
	local lower = nil
	local lower_offset = nil
	for _, offset in ipairs(LOWER_PROBE_OFFSETS) do
		local probe_origin = current_top
			+ self.Normal * offset
			- Vector3.new(0, 0.15, 0)
		local candidate = self:_cast(
			probe_origin,
			Vector3.new(0, -(MAX_GRAB_HEIGHT + 0.5), 0)
		)
		if not candidate then
			self:_debug("lower probe offset %.2f: ray missed", offset)
		elseif candidate.Normal.Y < 0.5 then
			self:_debug(
				"lower probe offset %.2f: hit %s with non-walkable normal=%s",
				offset,
				candidate.Instance:GetFullName(),
				tostring(candidate.Normal)
			)
		elseif not self:_is_climbable(candidate.Instance) then
			self:_debug(
				"lower probe offset %.2f: hit %s (not climbable)",
				offset,
				candidate.Instance:GetFullName()
			)
		else
			local drop = current_top.Y - candidate.Position.Y
			if drop >= 0.5 and drop <= MAX_GRAB_HEIGHT then
				lower = candidate
				lower_offset = offset
				break
			end
			self:_debug(
				"lower probe offset %.2f: hit %s but drop %.2f is out of range",
				offset,
				candidate.Instance:GetFullName(),
				drop
			)
		end
	end

	if not lower then
		self:_debug("lower ledge: no valid tagged lower surface found")
		return
	end

	local drop = current_top.Y - lower.Position.Y
	self:_debug(
		"lower ledge accepted; surface=%s drop=%.2f probe_offset=%.2f",
		lower.Instance:GetFullName(),
		drop,
		lower_offset
	)
	self.Surface = lower.Instance
	self.HangPosition = lower.Position + self.Normal * WALL_GAP - Vector3.new(0, HANG_DROP, 0)
	self:_position_hanging()
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
	-- Project the guide's horizontal bounding box onto the character's
	-- sideways axis so a long guide remains climbable away from its center.
	local right = flatten(top.BoxCFrame.RightVector)
	local look = flatten(top.BoxCFrame.LookVector)
	return math.abs(tangent:Dot(right)) * top.BoxSize.X * 0.5
		+ math.abs(tangent:Dot(look)) * top.BoxSize.Z * 0.5
end

function ParkourController:_get_hang_position_for_top(top, normal, tangent, lateral_offset)
	-- W transfers the hang to the next guide; preserve the character's
	-- sideways location on that guide instead of snapping to its center.
	return top.Position
		+ tangent * (lateral_offset or 0)
		+ normal * WALL_GAP
		- Vector3.new(0, HANG_DROP, 0)
end

function ParkourController:_transfer_hang_to_ledge(top, normal, tangent, lateral_offset)
	local root = self.Root
	if not root or not top or not tangent then return false end

	local hang_position = self:_get_hang_position_for_top(top, normal, tangent, lateral_offset)
	self.State = "Hanging"
	self.Surface = top.Guide or top.Instance
	self.Normal = normal
	self.HangPosition = hang_position

	-- Keep the existing hang lock and movement restriction; do not release
	-- the character or make the non-collidable guide physically solid.
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	self:_position_hanging()
	self:_debug(
		"climbed to higher ledge; guide=%s hang=%s state=%s",
		top.Instance:GetFullName(),
		tostring(hang_position),
		self.State
	)
	return true
end

function ParkourController:_get_guide_top(guide)
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

	local up = box_cframe.UpVector
	if up.Y < 0.5 then
		return nil
	end

	-- Keep the tagged guide itself so a Model guide can be retained as the
	-- hanging surface even when its diagnostic BasePart is nested inside it.
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
	if self.State ~= "Hanging" or not self.Root or not self.HangPosition or not self.Normal then
		self:_debug("mantle aborted; missing hanging state or character parts")
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
					local hang_position = self:_get_hang_position_for_top(
						top,
						normal,
						tangent,
						target_lateral_offset
					)
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
		self:_transfer_hang_to_ledge(best_top, normal, tangent, best_lateral_offset)
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
	self.Surface = nil
	self.Normal = nil
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
