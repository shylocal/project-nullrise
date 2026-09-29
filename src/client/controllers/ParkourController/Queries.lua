local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Vector = require(ReplicatedStorage.shared.utility.Vector)

local Config = require(script.Parent.Config)
local ClimbableQuery = require(script.Parent.ClimbableQuery)

local Queries = {}

function Queries.cast(self, origin, direction, respect_can_collide)
	local params = self._castParams or RaycastParams.new()
	self._castParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = respect_can_collide == true
	return Workspace:Raycast(origin, direction, params)
end
function Queries.cast_climbable_side(self, origin, direction)
	local params = self._sideCastParams or RaycastParams.new()
	self._sideCastParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local exclusions = { self.Character }
	for _ = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local hit = Workspace:Raycast(origin, direction, params)
		if not hit then
			return nil
		end
		if ClimbableQuery.is_climbable(hit.Instance) then
			return hit
		end

		-- Skip decorative non-collidable geometry, but never ray through a
		-- solid non-climbable wall or platform.
		if not hit.Instance:IsA("BasePart") or hit.Instance.CanCollide then
			return nil
		end
		table.insert(exclusions, hit.Instance)
	end
	return nil
end
function Queries.cast_reachable_grab_top(self, wall_position, wall_normal, root_position, reference_y)
	-- Several climb guides can overlap vertically. A single downward ray hits
	-- the highest one first, even when that ledge is outside grab range. Walk
	-- down through successive hits and choose the climbable, walkable top closest
	-- in height to the character.
	local standing_height = self:_standing_height()
	local origin = Vector3.new(
		wall_position.X,
		root_position.Y + Config.MaxGrabHeight + standing_height + 2,
		wall_position.Z
	) - wall_normal * 0.1
	local direction = Vector3.new(
		0,
		-(Config.MaxGrabHeight * 2 + standing_height + 4),
		0
	)

	local params = self._reachableTopParams or RaycastParams.new()
	self._reachableTopParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character }
	params.IgnoreWater = true
	params.RespectCanCollide = false

	local exclusions = { self.Character }
	local best = nil
	local best_height_distance = math.huge
	for hit_index = 1, Config.MaxTopSurfaceHits do
		params.FilterDescendantsInstances = exclusions
		local candidate = Workspace:Raycast(origin, direction, params)
		if not candidate then
			break
		end

		local height_delta = (reference_y or root_position.Y) - candidate.Position.Y
		local height_distance = math.abs(height_delta)
		local climbable = ClimbableQuery.is_climbable(candidate.Instance)
		local walkable = candidate.Normal.Y >= 0.5
		local reachable = height_delta >= -Config.MaxGrabHeight
			and height_delta <= Config.MaxGrabHeight

		if climbable and walkable and reachable and height_distance < best_height_distance then
			best = candidate
			best_height_distance = height_distance
		end

		table.insert(exclusions, candidate.Instance)
	end

	return best
end
function Queries.detect_surface(self)
	local humanoid = self.Humanoid
	if not humanoid or humanoid.Health <= 0 or humanoid.Sit then return nil end
	local humanoid_state = humanoid:GetState()
	if humanoid_state == Enum.HumanoidStateType.Dead
		or humanoid_state == Enum.HumanoidStateType.Swimming
		or humanoid_state == Enum.HumanoidStateType.Climbing then return nil end
	local root = self.Root
	if not root then
				return nil
	end

	local direction = Vector.flatten(root.CFrame.LookVector)
	if direction.Magnitude < 0.1 then
				return nil
	end
	direction = direction.Unit

	local origin = root.Position + Vector3.new(0, 1.1, 0)
	local wall = Queries.cast(self, origin, direction * Config.WallReach)
	if not wall then
				return nil
	end
	if not ClimbableQuery.is_climbable(wall.Instance) then
				return nil
	end

	local top = Queries.cast_reachable_grab_top(self, wall.Position, wall.Normal, root.Position, root.Position.Y)
	if not top then
				return nil
	end
	if not ClimbableQuery.is_climbable(top.Instance) then
				return nil
	end

	local height_delta = root.Position.Y - top.Position.Y
	if height_delta < -Config.MaxGrabHeight or height_delta > Config.MaxGrabHeight then
				return nil
	end

	local hang_normal = Vector.flatten(wall.Normal)
	if hang_normal.Magnitude < 0.05 then
				return nil
	end
	hang_normal = hang_normal.Unit
	local hang_position = top.Position + hang_normal * Config.WallGap - Vector3.new(0, Config.HangDrop, 0)
	local body_clear = Queries.has_hang_body_clearance(self, hang_position, hang_normal)
	if not body_clear then
				return nil
	end

		return ClimbableQuery.get_guide(top.Instance), hang_normal, hang_position
end
function Queries.has_hang_body_clearance(self, position, normal)
	local root = self.Root
	local character = self.Character
	if not root or not character or not position or not normal then
		return false
	end

	local facing = Vector.flatten(normal)
	if facing.Magnitude < 0.05 then
		return false
	end
	facing = facing.Unit

	-- Use the HumanoidRootPart collision envelope rather than the whole avatar
	-- bounding box. Accessories and non-colliding limbs can extend well beyond
	-- the actual movement collider and falsely reject tight but valid corners.
	local target_cframe = CFrame.lookAt(position, position - facing)
	-- Query with a box-shaped probe against exact part geometry. The bounds
	-- query below can treat a cylinder's enclosing box as solid, falsely
	-- rejecting otherwise clear positions beside its curved surface.
	local probe = self.HangClearanceProbe
	if not probe or not probe.Parent then
		probe = Instance.new("Part")
		probe.Name = "ParkourHangClearanceProbe"
		probe.Anchored = true
		probe.CanCollide = false
		probe.CanTouch = false
		probe.CanQuery = true
		probe.CollisionGroup = "Climbable"
		probe.Transparency = 1
		probe.CastShadow = false
		probe.Parent = Workspace
		self.HangClearanceProbe = probe
	end
	probe.Size = root.Size + Vector3.new(0.08, 0.08, 0.08)
	probe.CFrame = target_cframe
	local overlap_params = self._hangOverlapParams or OverlapParams.new()
	self._hangOverlapParams = overlap_params
	overlap_params.FilterType = Enum.RaycastFilterType.Exclude
	overlap_params.FilterDescendantsInstances = { character, probe }
	-- Collision filtering excludes Climbable geometry from this clearance query.
	overlap_params.CollisionGroup = "Climbable"
	overlap_params.RespectCanCollide = true

	local overlaps = Workspace:GetPartsInPart(probe, overlap_params)
	for _, part in ipairs(overlaps) do
		if part.CanCollide then
						return false, part
		end
	end

	return true
end
function Queries.has_vault_clearance(self, cframe, size, obstacle)
	local params = self._vaultOverlapParams or OverlapParams.new()
	self._vaultOverlapParams = params
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.Character, obstacle }
	params.RespectCanCollide = true

	local root = self.Root
	if root then
		params.CollisionGroup = root.CollisionGroup
	end

	for _, part in ipairs(Workspace:GetPartBoundsInBox(cframe, size, params)) do
		if part.CanCollide then
			return false, part
		end
	end

	return true
end

return Queries
