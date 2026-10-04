--!strict
-- Clones a weapon template into a character: weapon parts become visual-only,
-- each Wield entry is joined to its character limb with a Motor6D, and
-- hitpoint attachments are tagged for hit validation.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local World = require(ReplicatedStorage.shared.config).World

local HITPOINT_TAG = World.Tags.Hitpoint
local HITPOINT_ATTACHMENT = World.Names.HitpointAttachment

local WeaponAttachment = {}

local function get_root(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end

	local primary = if instance:IsA("Model") then instance.PrimaryPart else nil
	return primary or instance:FindFirstChildWhichIsA("BasePart", true) :: BasePart?
end

local function warn_attachment(instance: Instance, message: string)
	warn(("[WeaponAttachment] %s: %s"):format(instance:GetFullName(), message))
end

-- Weapon geometry is visual only: it never collides, never adds mass, and
-- is invisible to spatial queries, so hit and line-of-sight casts pass
-- through a held weapon to the body behind it.
local function prepare_part(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.Massless = true
end

local function prepare(instance: Instance): Instance?
	if instance:IsA("BasePart") then
		prepare_part(instance)

		return instance
	end

	if not instance:IsA("Model") then
		return nil
	end

	local root = get_root(instance)
	if not root then
		return nil
	end

	for _, descendant in instance:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end

		prepare_part(descendant)
	end

	return instance
end

local function tag_hitpoints(instance: Instance)
	for _, descendant in instance:GetDescendants() do
		if not descendant:IsA("Attachment") or descendant.Name ~= HITPOINT_ATTACHMENT then
			continue
		end

		CollectionService:AddTag(descendant, HITPOINT_TAG)
	end
end

-- Weapon wield mappings and animations target R6 limb names. Avatar type is
-- a game setting the client also checks, so the server cannot trust it and
-- must refuse to arm any other rig.
function WeaponAttachment.IsSupportedRig(character: Instance?): (boolean, string?)
	if character == nil or typeof(character) ~= "Instance" then
		return false, "character is missing"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "character has no Humanoid"
	end

	if humanoid.RigType ~= Enum.HumanoidRigType.R6 then
		return false, ("expected an R6 rig, got %s"):format(humanoid.RigType.Name)
	end

	return true, nil
end

-- `wield` maps a weapon part name to the character part it is joined to. It
-- is checked here (not trusted), so a malformed mapping is warned about:
-- a non-table mapping rejects the clone, bad entries are skipped.
-- Returns the parented clone, or nil (after a warning) when it is unusable.
function WeaponAttachment.Attach(source: Instance, wield: unknown, character: Instance): Instance?
	local clone = source:Clone()
	clone.Parent = character

	if not prepare(clone) then
		warn_attachment(clone, "expected a BasePart or a Model containing at least one BasePart")
		clone:Destroy()
		return nil
	end

	local root = get_root(clone)
	if not root then
		warn_attachment(clone, "could not resolve a root BasePart")
		clone:Destroy()
		return nil
	end

	local mapping: any = wield
	if mapping ~= nil and type(mapping) ~= "table" then
		warn_attachment(clone, "wield mapping must be a table")
		clone:Destroy()
		return nil
	end

	for wield_name, character_part_name in pairs(mapping or {}) do
		if typeof(wield_name) ~= "string" or wield_name == "" then
			warn_attachment(clone, ("invalid wield item name %q"):format(tostring(wield_name)))
			continue
		end

		if typeof(character_part_name) ~= "string" or character_part_name == "" then
			warn_attachment(clone, ("invalid character part name for wield item %q"):format(wield_name))
			continue
		end

		local wielded = clone:FindFirstChild(wield_name, true)
		local target = character:FindFirstChild(character_part_name, true)

		if not wielded then
			warn_attachment(clone, ("missing wield part %q"):format(tostring(wield_name)))
			continue
		end

		if not wielded:IsA("BasePart") then
			warn_attachment(clone, ("wield item %q must be a BasePart"):format(tostring(wield_name)))
			continue
		end

		if not target then
			warn_attachment(clone, ("missing character part %q for wield item %q"):format(
				tostring(character_part_name),
				tostring(wield_name)
			))
			continue
		end

		if not target:IsA("BasePart") then
			warn_attachment(clone, ("character item %q for wield item %q must be a BasePart"):format(
				tostring(character_part_name),
				tostring(wield_name)
			))
			continue
		end

		local motor6d = Instance.new("Motor6D")
		motor6d.Part0 = target :: BasePart
		motor6d.Part1 = wielded :: BasePart
		motor6d.Parent = wielded
	end

	tag_hitpoints(clone)

	return clone
end

return table.freeze(WeaponAttachment)
