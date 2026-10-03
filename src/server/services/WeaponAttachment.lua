local CollectionService = game:GetService("CollectionService")

local WeaponAttachment = {}

local function get_root(instance)
	if instance:IsA("BasePart") then
		return instance
	end

	return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
end

local function warn_attachment(instance, message)
	warn(("[WeaponAttachment] %s: %s"):format(instance:GetFullName(), message))
end

local function prepare(instance)
	if instance:IsA("BasePart") then
		instance.Anchored = false
		instance.CanCollide = false
		instance.Massless = true

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

		descendant.Anchored = false
		descendant.CanCollide = false
		descendant.Massless = true
	end

	return instance
end

local function tag_hitpoints(instance)
	for _, descendant in instance:GetDescendants() do
		if not descendant:IsA("Attachment") or descendant.Name ~= "Hitpoint" then
			continue
		end

		CollectionService:AddTag(descendant, "Hitpoint")
	end
end

-- Weapon wield mappings and animations target R6 limb names. Avatar type is
-- a game setting the client also checks, so the server cannot trust it and
-- must refuse to arm any other rig.
function WeaponAttachment.IsSupportedRig(character)
	if typeof(character) ~= "Instance" then
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

function WeaponAttachment.Attach(source, wield, character)
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

	if wield ~= nil and typeof(wield) ~= "table" then
		warn_attachment(clone, "wield mapping must be a table")
		clone:Destroy()
		return nil
	end

	for wield_name, character_part_name in pairs(wield or {}) do
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
		motor6d.Part0 = target
		motor6d.Part1 = wielded
		motor6d.Parent = wielded
	end

	tag_hitpoints(clone)

	return clone
end

return WeaponAttachment
