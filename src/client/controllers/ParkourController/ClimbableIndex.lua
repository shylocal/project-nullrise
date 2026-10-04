--!strict
-- Spatial index of Climbable-tagged guides under a root (Workspace).
--
-- Guides are tracked through the tag's added/removed signals and each guide's
-- AncestryChanged, so only descendants of `root` are indexed. A guide's
-- bounds (BasePart CFrame/Size, Model GetBoundingBox) are measured once and
-- cached in a hash grid. A BasePart guide whose CFrame or Size property
-- changes, or a Model guide whose descendants change (streaming), is marked
-- dirty and re-measured lazily by the next query. A static Model guide is
-- also re-measured when its pivot or the CFrame of one reference part has
-- changed since it was measured (PivotTo, tweens, a moving PrimaryPart); each
-- query checks that with two property reads per Model guide. A guide with the
-- ClimbableDynamic attribute, an unanchored BasePart guide and a Model guide
-- containing an unanchored BasePart are re-measured on every query instead.
-- The module-level instance from `get` outlives every character.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

type ConnectionLike = { Disconnect: (any) -> () }
export type CollectionServiceLike = {
	GetTagged: (any, string) -> { Instance },
	GetInstanceAddedSignal: (any, string) -> any,
	GetInstanceRemovedSignal: (any, string) -> any,
}

-- Guides spanning more cells than this are kept in a flat list instead.
local MAX_CELLS_PER_GUIDE = 512
-- Cell coordinates are packed into one number; this keeps them in range.
local CELL_OFFSET = 2 ^ 16
local CELL_SPAN = 2 ^ 17
-- Query boxes are padded so surface hits exactly on a guide's bound still overlap.
local QUERY_PADDING = 0.1

type Entry = {
	Instance: Instance,
	Measurable: boolean,
	Dynamic: boolean,
	CFrame: CFrame,
	Size: Vector3,
	Min: Vector3,
	Max: Vector3,
	Cells: { number }?,
	-- Model guides only: the pivot, a reference part and its CFrame when
	-- measured. A change to either means the Model moved.
	Pivot: CFrame?,
	Reference: BasePart?,
	ReferenceCFrame: CFrame?,
}

local ClimbableIndex = {}
ClimbableIndex.__index = ClimbableIndex

export type ClimbableIndex = typeof(setmetatable(
	{} :: {
		Tag: string,
		Root: Instance,
		CellSize: number,
		_entries: { [Instance]: Entry },
		_watch: { [Instance]: { RBXScriptConnection } },
		_grid: { [number]: { [Instance]: boolean } },
		_large: { [Instance]: boolean },
		_dynamic: { [Instance]: boolean },
		-- Indexed (cached, non-dynamic) Model guides, checked for movement.
		_models: { [Instance]: boolean },
		_dirty: { [Instance]: boolean },
		_connections: { ConnectionLike },
		_destroyed: boolean,
	},
	ClimbableIndex
))

local function world_aabb(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size * 0.5
	local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
	local extent = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	)
	return cframe.Position - extent, cframe.Position + extent
end

local function measure(instance: Instance): (boolean, CFrame, Vector3)
	if instance:IsA("BasePart") then
		return true, instance.CFrame, instance.Size
	elseif instance:IsA("Model") then
		local cframe, size = instance:GetBoundingBox()
		return true, cframe, size
	end
	return false, CFrame.identity, Vector3.zero
end

-- Whether a Model contains an unanchored BasePart (physics moves it without
-- any property signal), and its first BasePart as a movement reference.
local function scan_model(model: Model): (boolean, BasePart?)
	local reference: BasePart? = model.PrimaryPart
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if not descendant.Anchored then
				return true, reference or descendant
			end
			if not reference then
				reference = descendant
			end
		end
	end
	return false, reference
end

-- True when a cached Model guide moved since it was measured.
local function model_moved(entry: Entry): boolean
	local pivot = entry.Pivot
	if not pivot then
		return false
	end
	local model = entry.Instance :: Model
	if model:GetPivot() ~= pivot then
		return true
	end
	local reference = entry.Reference
	return reference ~= nil and reference.CFrame ~= entry.ReferenceCFrame
end

local function overlaps(min_a: Vector3, max_a: Vector3, min_b: Vector3, max_b: Vector3): boolean
	return min_a.X <= max_b.X and max_a.X >= min_b.X
		and min_a.Y <= max_b.Y and max_a.Y >= min_b.Y
		and min_a.Z <= max_b.Z and max_a.Z >= min_b.Z
end

local function cell_key(x: number, y: number, z: number): number
	return ((x + CELL_OFFSET) * CELL_SPAN + (y + CELL_OFFSET)) * CELL_SPAN + (z + CELL_OFFSET)
end

function ClimbableIndex.new(deps: {
	collection: CollectionServiceLike,
	tag: string,
	cell_size: number,
	root: Instance,
}): ClimbableIndex
	Deps.check(deps, "ClimbableIndex", { "collection", "tag", "cell_size", "root" })
	assert(type(deps.cell_size) == "number" and deps.cell_size > 0, "ClimbableIndex.new: cell_size must be > 0")

	local self = setmetatable({
		Tag = deps.tag,
		Root = deps.root,
		CellSize = deps.cell_size,
		_entries = {},
		_watch = {},
		_grid = {},
		_large = {},
		_dynamic = {},
		_models = {},
		_dirty = {},
		_connections = {},
		_destroyed = false,
	}, ClimbableIndex)

	local collection = deps.collection
	table.insert(self._connections, collection:GetInstanceAddedSignal(deps.tag):Connect(function(instance: Instance)
		self:_track(instance)
	end))
	table.insert(self._connections, collection:GetInstanceRemovedSignal(deps.tag):Connect(function(instance: Instance)
		self:_untrack(instance)
	end))
	for _, instance in collection:GetTagged(deps.tag) do
		self:_track(instance)
	end
	return self
end

local default_index: ClimbableIndex? = nil

-- The shared index over CollectionService and World.Tags.Climbable.
function ClimbableIndex.get(): ClimbableIndex
	local index = default_index
	if not index then
		index = ClimbableIndex.new({
			-- CollectionService satisfies CollectionServiceLike; the engine type is wider.
			collection = CollectionService :: any,
			tag = Config.World.Tags.Climbable,
			cell_size = 16,
			root = Workspace,
		})
		default_index = index
	end
	return index :: ClimbableIndex
end

function ClimbableIndex._grid_remove(self: ClimbableIndex, entry: Entry)
	local instance = entry.Instance
	local cells = entry.Cells
	if cells then
		for _, key in cells do
			local cell = self._grid[key]
			if cell then
				cell[instance] = nil
				if next(cell) == nil then
					self._grid[key] = nil
				end
			end
		end
		entry.Cells = nil
	end
	self._large[instance] = nil
	self._dynamic[instance] = nil
	self._models[instance] = nil
end

function ClimbableIndex._grid_insert(self: ClimbableIndex, entry: Entry)
	local instance = entry.Instance
	if not entry.Measurable then
		return
	end
	if entry.Dynamic then
		self._dynamic[instance] = true
		return
	end
	if entry.Pivot then
		self._models[instance] = true
	end

	local cell_size = self.CellSize
	local x0, y0, z0 = math.floor(entry.Min.X / cell_size), math.floor(entry.Min.Y / cell_size), math.floor(entry.Min.Z / cell_size)
	local x1, y1, z1 = math.floor(entry.Max.X / cell_size), math.floor(entry.Max.Y / cell_size), math.floor(entry.Max.Z / cell_size)
	local count = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
	if count > MAX_CELLS_PER_GUIDE then
		self._large[instance] = true
		return
	end

	local cells = {}
	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local key = cell_key(x, y, z)
				local cell = self._grid[key]
				if not cell then
					cell = {}
					self._grid[key] = cell
				end
				cell[instance] = true
				table.insert(cells, key)
			end
		end
	end
	entry.Cells = cells
end

-- (Re)measures a tracked guide that is a descendant of root, or drops it.
function ClimbableIndex._refresh(self: ClimbableIndex, instance: Instance)
	self._dirty[instance] = nil
	local entry = self._entries[instance]
	if entry then
		self:_grid_remove(entry)
	end
	if self._watch[instance] == nil or not instance:IsDescendantOf(self.Root) then
		self._entries[instance] = nil
		return
	end

	local measurable, cframe, size = measure(instance)
	local min, max = world_aabb(cframe, size)
	-- Physically simulated parts move without property signals, so they
	-- are measured live like an explicitly dynamic guide.
	local dynamic = instance:GetAttribute(Config.World.Attributes.ClimbableDynamic) == true
		or (instance:IsA("BasePart") and not instance.Anchored)
	local pivot: CFrame? = nil
	local reference: BasePart? = nil
	local reference_cframe: CFrame? = nil
	if instance:IsA("Model") then
		local has_unanchored, first_part = scan_model(instance)
		dynamic = dynamic or has_unanchored
		if not dynamic then
			pivot = instance:GetPivot()
			reference = first_part
			reference_cframe = if first_part then first_part.CFrame else nil
		end
	end
	local fresh: Entry = {
		Instance = instance,
		Measurable = measurable,
		Dynamic = dynamic,
		CFrame = cframe,
		Size = size,
		Min = min,
		Max = max,
		Cells = nil,
		Pivot = pivot,
		Reference = reference,
		ReferenceCFrame = reference_cframe,
	}
	self._entries[instance] = fresh
	self:_grid_insert(fresh)
end

function ClimbableIndex._track(self: ClimbableIndex, instance: Instance)
	if self._destroyed or self._watch[instance] ~= nil then
		return
	end
	local connections: { RBXScriptConnection } = {}
	self._watch[instance] = connections
	local function refresh()
		self:_refresh(instance)
	end
	local function mark_dirty()
		if self._entries[instance] then
			self._dirty[instance] = true
		end
	end
	table.insert(connections, instance.AncestryChanged:Connect(refresh))
	table.insert(connections, instance:GetAttributeChangedSignal(Config.World.Attributes.ClimbableDynamic):Connect(refresh))
	if instance:IsA("BasePart") then
		table.insert(connections, instance:GetPropertyChangedSignal("CFrame"):Connect(mark_dirty))
		table.insert(connections, instance:GetPropertyChangedSignal("Size"):Connect(mark_dirty))
		table.insert(connections, instance:GetPropertyChangedSignal("Anchored"):Connect(refresh))
	elseif instance:IsA("Model") then
		table.insert(connections, instance.DescendantAdded:Connect(mark_dirty))
		table.insert(connections, instance.DescendantRemoving:Connect(mark_dirty))
	end
	self:_refresh(instance)
end

function ClimbableIndex._untrack(self: ClimbableIndex, instance: Instance)
	local connections = self._watch[instance]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		self._watch[instance] = nil
	end
	self._dirty[instance] = nil
	local entry = self._entries[instance]
	if entry then
		self:_grid_remove(entry)
		self._entries[instance] = nil
	end
end

function ClimbableIndex._flush(self: ClimbableIndex)
	local entries = self._entries
	for instance in self._models do
		if model_moved(entries[instance]) then
			self._dirty[instance] = true
		end
	end
	if next(self._dirty) == nil then
		return
	end
	local dirty = {}
	for instance in self._dirty do
		table.insert(dirty, instance)
	end
	for _, instance in dirty do
		self:_refresh(instance)
	end
end

-- Guides whose cached world AABB overlaps the AABB of the oriented box.
function ClimbableIndex.QueryBox(self: ClimbableIndex, cframe: CFrame, size: Vector3): { Instance }
	self:_flush()
	local min, max = world_aabb(cframe, size + Vector3.one * (QUERY_PADDING * 2))
	local results: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	local entries = self._entries

	local function consider(instance: Instance, entry_min: Vector3, entry_max: Vector3)
		if not seen[instance] then
			seen[instance] = true
			if overlaps(min, max, entry_min, entry_max) then
				table.insert(results, instance)
			end
		end
	end

	local cell_size = self.CellSize
	for x = math.floor(min.X / cell_size), math.floor(max.X / cell_size) do
		for y = math.floor(min.Y / cell_size), math.floor(max.Y / cell_size) do
			for z = math.floor(min.Z / cell_size), math.floor(max.Z / cell_size) do
				local cell = self._grid[cell_key(x, y, z)]
				if cell then
					for instance in cell do
						local entry = entries[instance]
						consider(instance, entry.Min, entry.Max)
					end
				end
			end
		end
	end
	for instance in self._large do
		local entry = entries[instance]
		consider(instance, entry.Min, entry.Max)
	end
	for instance in self._dynamic do
		local _, live_cframe, live_size = measure(instance)
		local live_min, live_max = world_aabb(live_cframe, live_size)
		consider(instance, live_min, live_max)
	end
	return results
end

-- The indexed guide that is `instance` or its nearest ancestor below root.
function ClimbableIndex.GuideOf(self: ClimbableIndex, instance: Instance?): Instance?
	local entries = self._entries
	local root = self.Root
	local current = instance
	while current and current ~= root do
		if entries[current] then
			return current
		end
		current = current.Parent
	end
	return nil
end

function ClimbableIndex.IsClimbable(self: ClimbableIndex, instance: Instance?): boolean
	return self:GuideOf(instance) ~= nil
end

-- Bounds of a guide: cached for static Models (re-measured once they move),
-- live for BaseParts (as cheap as a cache read) and for dynamic or unindexed
-- guides.
function ClimbableIndex.Bounds(self: ClimbableIndex, guide: Instance): (CFrame, Vector3)
	local entry = self._entries[guide]
	if self._dirty[guide] or (entry and model_moved(entry)) then
		self:_refresh(guide)
		entry = self._entries[guide]
	end
	if entry and entry.Measurable and not entry.Dynamic and not guide:IsA("BasePart") then
		return entry.CFrame, entry.Size
	end
	local measurable, cframe, size = measure(guide)
	if not measurable then
		error(("ClimbableIndex:Bounds: %s is neither a BasePart nor a Model"):format(guide:GetFullName()), 2)
	end
	return cframe, size
end

function ClimbableIndex.Destroy(self: ClimbableIndex)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	local tracked = {}
	for instance in self._watch do
		table.insert(tracked, instance)
	end
	for _, instance in tracked do
		self:_untrack(instance)
	end
	if default_index == self then
		default_index = nil
	end
end

return ClimbableIndex
