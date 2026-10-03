local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local CombatValidation = require(Services.CombatValidation)

local function make_character(name, position, created)
	local character = Instance.new("Model")
	character.Name = name
	character.Parent = Workspace
	table.insert(created, character)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 2)
	root.CFrame = CFrame.new(position)
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	return character, root
end

local function make_active(attacker, wielded)
	local segment = Instance.new("Attachment")
	segment.Name = "Hitpoint"
	segment.Parent = wielded
	CollectionService:AddTag(segment, "Hitpoint")

	local active = {
		Character = attacker,
		Wielded = wielded,
		Attack = {
			Hitbox = "TestHitbox",
			Range = 8,
			NetworkTolerance = 3,
		},
		ValidationRaycastParams = RaycastParams.new(),
	}

	return active, segment
end

local function make_weapon_service(wielded)
	return {
		GetWielded = function()
			return wielded
		end,
	}
end

return function()
	describe("CombatValidation hit boundary", function()
		local created

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		it("rejects missing hitpoint arguments instead of skipping spatial validation", function()
			local attacker = make_character("Attacker", Vector3.zero, created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = Instance.new("Part")
			wielded.Name = "TestHitbox"
			wielded.Parent = attacker

			local active = make_active(attacker, wielded)
			local weapon_service = make_weapon_service(wielded)

			expect(CombatValidation.ValidateHit(
				weapon_service,
				{},
				active,
				target,
				nil,
				Vector3.new(0, 0, -6)
			)).to.equal(nil)

			expect(CombatValidation.ValidateHit(
				weapon_service,
				{},
				active,
				target,
				active.Wielded:FindFirstChild("Hitpoint"),
				nil
			)).to.equal(nil)
		end)

		it("accepts a hit with valid segment, position, range, facing, and line of sight", function()
			local attacker = make_character("Attacker", Vector3.zero, created)
			attacker.HumanoidRootPart.CFrame = CFrame.lookAt(attacker.HumanoidRootPart.Position, Vector3.new(0, 0, -1))
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = Instance.new("Part")
			wielded.Name = "TestHitbox"
			wielded.CFrame = attacker.HumanoidRootPart.CFrame
			wielded.Parent = attacker
			table.insert(created, wielded)

			local active, segment = make_active(attacker, wielded)
			local result = CombatValidation.ValidateHit(
				make_weapon_service(wielded),
				{},
				active,
				target,
				segment,
				target.HumanoidRootPart.Position
			)

			expect(result).to.equal(target:FindFirstChildOfClass("Humanoid"))
		end)

		it("rejects targets behind the attacker", function()
			local attacker = make_character("Attacker", Vector3.zero, created)
			attacker.HumanoidRootPart.CFrame = CFrame.lookAt(attacker.HumanoidRootPart.Position, Vector3.new(0, 0, -1))
			local target = make_character("Target", Vector3.new(0, 0, 6), created)
			local wielded = Instance.new("Part")
			wielded.Name = "TestHitbox"
			wielded.Parent = attacker
			table.insert(created, wielded)

			local active, segment = make_active(attacker, wielded)
			local result = CombatValidation.ValidateHit(
				make_weapon_service(wielded),
				{},
				active,
				target,
				segment,
				target.HumanoidRootPart.Position
			)

			expect(result).to.equal(nil)
		end)

		it("rejects an obstruction between the weapon hitpoint and impact position", function()
			local attacker = make_character("Attacker", Vector3.zero, created)
			attacker.HumanoidRootPart.CFrame = CFrame.lookAt(attacker.HumanoidRootPart.Position, Vector3.new(0, 0, -1))
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = Instance.new("Part")
			wielded.Name = "TestHitbox"
			wielded.CFrame = attacker.HumanoidRootPart.CFrame
			wielded.Parent = attacker
			table.insert(created, wielded)

			local wall = Instance.new("Part")
			wall.Name = "Wall"
			wall.Size = Vector3.new(4, 6, 0.5)
			wall.CFrame = CFrame.new(0, 0, -3)
			wall.Parent = Workspace
			table.insert(created, wall)

			local active, segment = make_active(attacker, wielded)
			local result = CombatValidation.ValidateHit(
				make_weapon_service(wielded),
				{},
				active,
				target,
				segment,
				target.HumanoidRootPart.Position
			)

			expect(result).to.equal(nil)
		end)
	end)
end
