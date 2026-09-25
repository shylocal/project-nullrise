local CollectionService = game:GetService("CollectionService")

local WeaponAttachment = {}

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

	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true
		end
	end

	return instance
end

local function get_root(instance)
	if instance:IsA("BasePart") then
		return instance
	end

	return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
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

	if clone:IsA("Model") then
		for wield_name, character_part_name in pairs(wield or {}) do
			local wielded = clone:FindFirstChild(wield_name, true)
			local target = character:FindFirstChild(character_part_name, true)

			if wielded and target and target:IsA("BasePart") then
				local root = get_root(wielded)

				if root then
					local offset = clone:GetPivot():ToObjectSpace(root.CFrame)
					clone:PivotTo(target.CFrame * offset:Inverse())
					break
				end
			end
		end
	end

	for wield_name, character_part_name in pairs(wield or {}) do
		local wielded = clone:FindFirstChild(wield_name, true)
		local target = character:FindFirstChild(character_part_name, true)

		if not wielded or not target or not target:IsA("BasePart") then
			continue
		end

		local root = get_root(wielded)
		if not root then
			continue
		end

		if wielded:IsA("Model") then
			wielded:PivotTo(target.CFrame)
			root = get_root(wielded)
		else
			root.CFrame = target.CFrame
		end

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = target
		weld.Part1 = root
		weld.Parent = root
	end

	tag_hitpoints(clone)

	return clone
end

return WeaponAttachment
