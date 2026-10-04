--!strict
-- Verifies the Studio-authored weapon templates (ServerStorage.weapon_models)
-- against the weapon Catalog at boot: every template exists, every Wield part
-- and move Hitbox resolves to a BasePart, every hitbox carries a hitpoint
-- Attachment and moves with a wield part. The checks mirror how WeaponService
-- and WeaponAttachment resolve names at runtime (recursive FindFirstChild).
-- RuntimeContracts.spec runs the same Verify against the live place.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local World = require(ReplicatedStorage.shared.config).World

local HITPOINT_ATTACHMENT = World.Names.HitpointAttachment
local MODELS_FOLDER = World.Folders.WeaponModels

export type CatalogLike = {
	Ids: () -> { string },
	Get: (id: any) -> any,
}

local AssetContracts = {}

local function sorted_keys(map: { [any]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

-- The parts a constraint or joint connects, or nil for other instances.
local function joint_parts(instance: Instance): (Instance?, Instance?)
	if instance:IsA("WeldConstraint") then
		return instance.Part0, instance.Part1
	elseif instance:IsA("JointInstance") then
		return instance.Part0, instance.Part1
	elseif instance:IsA("RigidConstraint") then
		local a0, a1 = instance.Attachment0, instance.Attachment1
		return a0 and a0.Parent, a1 and a1.Parent
	end
	return nil, nil
end

local function in_template(template: Instance, instance: Instance?): boolean
	return instance ~= nil and instance:IsA("BasePart") and (instance == template or instance:IsDescendantOf(template))
end

-- Parts reachable from `roots` through welds, joints and rigid constraints
-- whose both ends are inside the template.
local function connected_parts(template: Instance, roots: { BasePart }): { [Instance]: boolean }
	local edges: { [Instance]: { Instance } } = {}
	local function link(a: Instance, b: Instance)
		local list = edges[a]
		if not list then
			list = {}
			edges[a] = list
		end
		table.insert(list, b)
	end
	local candidates = template:GetDescendants()
	table.insert(candidates, template)
	for _, instance in ipairs(candidates) do
		local part0, part1 = joint_parts(instance)
		if part0 and part1 and in_template(template, part0) and in_template(template, part1) then
			link(part0, part1)
			link(part1, part0)
		end
	end

	local reached: { [Instance]: boolean } = {}
	local queue: { Instance } = {}
	for _, root in ipairs(roots) do
		if not reached[root] then
			reached[root] = true
			table.insert(queue, root)
		end
	end
	local head = 1
	while head <= #queue do
		local part = queue[head]
		head += 1
		for _, other in ipairs(edges[part] or {}) do
			if not reached[other] then
				reached[other] = true
				table.insert(queue, other)
			end
		end
	end
	return reached
end

local function has_hitpoint(part: BasePart): boolean
	for _, descendant in ipairs(part:GetDescendants()) do
		if descendant:IsA("Attachment") and descendant.Name == HITPOINT_ATTACHMENT then
			return true
		end
	end
	return false
end

local function verify_weapon(errors: { string }, id: string, definition: any, models: Instance)
	local function fail(message: string)
		table.insert(errors, ("%s: %s"):format(id, message))
	end

	if type(definition) ~= "table" or type(definition.Model) ~= "string" then
		fail("catalog definition is missing")
		return
	end
	local template = models:FindFirstChild(definition.Model)
	if template == nil then
		fail(("template '%s' is missing from ServerStorage.%s"):format(definition.Model, MODELS_FOLDER))
		return
	end
	if not template:IsA("BasePart") and template:FindFirstChildWhichIsA("BasePart", true) == nil then
		fail(("template '%s' must be a BasePart or a Model containing one"):format(definition.Model))
		return
	end

	local wield_parts: { [string]: BasePart } = {}
	local wield_roots: { BasePart } = {}
	local wield = if type(definition.Wield) == "table" then definition.Wield else {}
	for _, wield_name in ipairs(sorted_keys(wield)) do
		local part = template:FindFirstChild(wield_name, true)
		if part == nil or not part:IsA("BasePart") then
			fail(("Wield.%s: no BasePart named '%s' in template '%s'"):format(wield_name, wield_name, definition.Model))
		else
			wield_parts[wield_name] = part
			table.insert(wield_roots, part)
		end
	end

	local reachable: { [Instance]: boolean }? = nil
	local moves = if type(definition.Moves) == "table" then definition.Moves else {}
	for _, move_name in ipairs(sorted_keys(moves)) do
		local move = moves[move_name]
		local hitbox_name = type(move) == "table" and move.Hitbox
		if type(hitbox_name) ~= "string" then
			continue
		end
		local path = ("Moves.%s.Hitbox"):format(move_name)
		-- Resolved like WeaponService:GetWielded: a wield part first, then anywhere.
		local hitbox: Instance? = wield_parts[hitbox_name] or template:FindFirstChild(hitbox_name, true)
		if hitbox == nil or not hitbox:IsA("BasePart") then
			fail(("%s: no BasePart named '%s' in template '%s'"):format(path, hitbox_name, definition.Model))
			continue
		end
		if not has_hitpoint(hitbox) then
			fail(("%s: '%s' has no Attachment named '%s'"):format(path, hitbox_name, HITPOINT_ATTACHMENT))
		end
		if reachable == nil then
			reachable = connected_parts(template, wield_roots)
		end
		if not (reachable :: { [Instance]: boolean })[hitbox] then
			fail(
				("%s: '%s' is neither a wield part nor welded/jointed to one, so it would not follow the arm"):format(
					path,
					hitbox_name
				)
			)
		end
	end
end

-- Returns every violation, in Catalog.Ids() order. `models` is the
-- ServerStorage.weapon_models folder (nil when the place lacks it).
function AssetContracts.Verify(catalog: CatalogLike, models: Instance?): { string }
	local errors = {}
	if models == nil then
		table.insert(errors, ("ServerStorage.%s is missing"):format(MODELS_FOLDER))
		return errors
	end
	for _, id in ipairs(catalog.Ids()) do
		verify_weapon(errors, id, catalog.Get(id), models)
	end
	return errors
end

-- Studio stops the boot with every problem listed, so broken content is
-- fixed before play; live servers keep running and warn each problem.
function AssetContracts.Report(errors: { string }, is_studio: boolean): ()
	if #errors == 0 then
		return
	end
	if is_studio then
		error("[AssetContracts] Weapon templates do not match the Catalog:\n" .. table.concat(errors, "\n"), 0)
	end
	for _, message in ipairs(errors) do
		warn("[AssetContracts] " .. message)
	end
end

return table.freeze(AssetContracts)
