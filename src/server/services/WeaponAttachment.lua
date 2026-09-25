local CollectionService = game:GetService("CollectionService")

local WeaponAttachment = {}

local function prepare(instance, target)
	if instance:IsA("BasePart") then
		instance.CFrame = target.CFrame
		instance.Anchored = false
		instance.CanCollide = false
		instance.Massless = true

		return instance
	end

	if not instance:IsA("Model") then
		return nil
	end

	local root = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	if not root then
		return nil
	end

	instance:PivotTo(target.CFrame)

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

	return root
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

function WeaponAttachment.Attach(source, target, parent)
	local clone = source:Clone()
	clone.Parent = parent

	local root = prepare(clone, target)
	if not root then
		clone:Destroy()
		return nil
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = root
	weld.Parent = root

	tag_hitpoints(clone)

	return clone
end

return WeaponAttachment
