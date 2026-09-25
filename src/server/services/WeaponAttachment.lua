local CollectionService = game:GetService("CollectionService")

local WeaponAttachment = {}

local function get_root(instance)
	if instance:IsA("BasePart") then
		return instance
	end

	return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
end

local function get_pivot(instance)
	if instance:IsA("BasePart") then
		return instance.CFrame
	end

	return instance:GetPivot()
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

		if descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end

	return instance
end

local function tag_hitpoints(instance)
	for _, descendant in instance:GetDescendants() do
		if not descendant:IsA("Attachment") or descendant.Name ~= "Hitpoint" then
			continue
		end

		CollectionService:AddTag(descendant, "DmgPoint")
		CollectionService:AddTag(descendant, "Hitpoint")
	end
end

function WeaponAttachment.Attach(source, wield, character)
	local clone = source:Clone()
	clone.Parent = character

	if not prepare(clone) then
		clone:Destroy()
		return nil
	end

	local root = get_root(clone)
	if not root then
		clone:Destroy()
		return nil
	end

	for wield_name, character_part_name in pairs(wield or {}) do
		local wielded = clone:FindFirstChild(wield_name, true)
		local target = character:FindFirstChild(character_part_name, true)

		if not wielded or not target or not target:IsA("BasePart") then
			continue
		end

		local offset = root.CFrame:ToObjectSpace(get_pivot(wielded))
		root.CFrame = target.CFrame * offset:Inverse()

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = target
		weld.Part1 = root
		weld.Parent = root

		break
	end

	tag_hitpoints(clone)

	return clone
end

return WeaponAttachment
