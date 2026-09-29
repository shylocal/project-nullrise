local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local ParkourController = {}
ParkourController.__index = ParkourController

local DEBUG_PARKOUR = true

local CLIMBABLE_TAG = "Climbable"
local WALL_REACH = 3.25
local MAX_GRAB_HEIGHT = 4.5
local HANG_DROP = 2.35
local WALL_GAP = 0.8
local TRAVERSE_SPEED = 5
local SURFACE_PROBE = 1.4
local MANTLE_INSET = 1.25
local MANTLE_SAMPLE_STEP = 0.75
local MANTLE_SAMPLE_COUNT = 4
local LOWER_PROBE_OFFSETS = { 0.15, 0.45, 0.75, 1.05 }

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
		if action == Actions.Jump and self.State == "Hanging" then
			-- Releasing Space simply lets go; normal gravity handles the drop.
			self:_release()
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

function ParkourController:_cast(origin, direction)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
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

function ParkourController:_cast_top_surface(wall_position, wall_normal, root_position)
	-- Start above the maximum reachable ledge, then sample just inside the wall
	-- footprint. Starting outside the footprint can miss narrow tops; starting
	-- below the top can leave the ray origin inside the wall and miss it.
	local top_origin = Vector3.new(
		wall_position.X,
		root_position.Y + MAX_GRAB_HEIGHT + 0.25,
		wall_position.Z
	) - wall_normal * 0.1
	local scan_depth = MAX_GRAB_HEIGHT * 2 + 1
	return self:_cast(top_origin, Vector3.new(0, -scan_depth, 0))
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

	local top = self:_cast_top_surface(wall.Position, wall.Normal, root.Position)
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
		if self.InputController:IsDown(Actions.Jump) then
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
			local top = self:_cast_top_surface(probe.Position, probe.Normal, root.Position)
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
	return (humanoid and humanoid.HipHeight or 2) + root.Size.Y * 0.5
end

function ParkourController:_has_standing_clearance(position, normal)
	local root = self.Root
	if not root then return false end

	-- Check the character-sized volume above the candidate floor. Keep a small
	-- gap at the bottom so the supporting ledge itself is not counted as an
	-- obstruction.
	local standing_height = self:_standing_height()
	local box_size = Vector3.new(
		root.Size.X * 1.35,
		math.max(1, standing_height * 2 - 0.2),
		root.Size.Z * 1.35
	)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }

	local facing = normal and -normal or root.CFrame.LookVector
	local bounds = Workspace:GetPartBoundsInBox(
		CFrame.lookAt(position, position + facing),
		box_size,
		params
	)
	for _, part in ipairs(bounds) do
		if part.CanCollide then
			return false, part
		end
	end
	return true, nil
end

function ParkourController:_complete_mantle(top, normal)
	local root = self.Root
	if not root or not top then return false end

	local standing_position = top.Position
		- normal * MANTLE_INSET
		+ Vector3.new(0, self:_standing_height() + 0.05, 0)
	local clear, blocker = self:_has_standing_clearance(standing_position, normal)
	if not clear then
		self:_debug(
			"mantle blocked by standing clearance; top=%s blocker=%s position=%s",
			top.Instance:GetFullName(),
			blocker and blocker:GetFullName() or "unknown",
			tostring(standing_position)
		)
		return false
	end

	self:_debug("mantle completed; top=%s position=%s", top.Instance:GetFullName(), tostring(standing_position))
	self:_release()
	root.CFrame = CFrame.lookAt(standing_position, standing_position - normal)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if self.Humanoid then
		self.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	return true
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
	local best_top = nil
	local best_height = -math.huge
	local best_offset = math.huge

	-- Sample from the current lip inward across the platform. This finds the
	-- current ledge as well as a reachable higher tier behind it.
	for sample_index = 0, MANTLE_SAMPLE_COUNT do
		local offset = sample_index * MANTLE_SAMPLE_STEP
		local sample_position = current_top - normal * offset
		local top = self:_cast_top_surface(sample_position, normal, root.Position)
		if not top then
			self:_debug("mantle sample %.2f: top ray missed", offset)
		else
			local climbable = self:_is_climbable(top.Instance)
			local height_delta = root.Position.Y - top.Position.Y
			local height_above_lip = top.Position.Y - current_top.Y
			if top.Normal.Y < 0.5 then
				self:_debug(
					"mantle sample %.2f: hit %s with non-walkable normal=%s",
					offset,
					top.Instance:GetFullName(),
					tostring(top.Normal)
				)
			elseif height_delta < -MAX_GRAB_HEIGHT or height_delta > MAX_GRAB_HEIGHT then
				self:_debug(
					"mantle sample %.2f: top=%s height_delta=%.2f out of range",
					offset,
					top.Instance:GetFullName(),
					height_delta
				)
			elseif height_above_lip < -0.25 then
				self:_debug(
					"mantle sample %.2f: top=%s is %.2f below current lip",
					offset,
					top.Instance:GetFullName(),
					height_above_lip
				)
			else
				-- Tagged ledges and ordinary visible walkable ground are both valid
				-- mantle destinations when there is clear standing room.
				local standing_position = top.Position
					- normal * MANTLE_INSET
					+ Vector3.new(0, self:_standing_height() + 0.05, 0)
				local clear, blocker = self:_has_standing_clearance(standing_position, normal)
				if not clear then
					self:_debug(
						"mantle sample %.2f: top=%s blocked by %s",
						offset,
						top.Instance:GetFullName(),
						blocker and blocker:GetFullName() or "unknown"
					)
				elseif height_above_lip > best_height
					or (height_above_lip == best_height and offset < best_offset) then
					best_top = top
					best_height = height_above_lip
					best_offset = offset
					self:_debug(
						"mantle candidate at %.2f: top=%s climbable=%s rise=%.2f",
						offset,
						top.Instance:GetFullName(),
						tostring(climbable),
						height_above_lip
					)
				end
			end
		end
	end

	if best_top then
		self:_debug(
			"mantle candidate selected; top=%s height_above_lip=%.2f sample_offset=%.2f",
			best_top.Instance:GetFullName(),
			best_height,
			best_offset
		)
		self:_complete_mantle(best_top, normal)
	else
		self:_debug("mantle found no valid standable top surface")
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
