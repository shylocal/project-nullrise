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
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 2)
	root.CFrame = CFrame.new(position)
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	return character, root
end

local function make_attacker(created)
	local attacker = make_character("Attacker", Vector3.zero, created)
	attacker.HumanoidRootPart.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
	return attacker
end

local function make_wielded(attacker, position)
	local wielded = Instance.new("Part")
	wielded.Name = "TestHitbox"
	wielded.Anchored = true
	wielded.CanCollide = false
	wielded.CFrame = CFrame.new(position)
	wielded.Parent = attacker
	return wielded
end

local function make_wall(position, created)
	local wall = Instance.new("Part")
	wall.Name = "Wall"
	wall.Anchored = true
	wall.Size = Vector3.new(4, 6, 0.5)
	wall.CFrame = CFrame.new(position)
	wall.Parent = Workspace
	table.insert(created, wall)
	return wall
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
			HitPositionTolerance = 3,
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

local function validate(wielded, active, target, segment, hit_position)
	return CombatValidation.ValidateHit(
		make_weapon_service(wielded),
		{},
		active,
		target,
		segment,
		hit_position
	)
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
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			expect(validate(wielded, active, target, nil, Vector3.new(0, 0, -6))).to.equal(nil)
			expect(validate(wielded, active, target, segment, nil)).to.equal(nil)
		end)

		it("accepts a hit with valid segment, position, range, facing, and line of sight", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(target:FindFirstChildOfClass("Humanoid"))
		end)

		it("rejects targets behind the attacker", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, 6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, 3))
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(nil)
		end)

		it("rejects an obstruction between attacker and target", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			make_wall(Vector3.new(0, 0, -4.5), created)
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(nil)
		end)

		it("rejects a wall hit even when the hitpoint-to-impact segment is clear", function()
			-- The reported impact sits on the attacker's side of the wall, so a
			-- ray from the weapon hitpoint to the impact never touches the wall.
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			make_wall(Vector3.new(0, 0, -4.5), created)
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, Vector3.new(0, 0, -4))

			expect(result).to.equal(nil)
		end)

		it("rejects an impact that is within weapon range of the target but not on its body", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -9), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			-- 1 stud from the hitpoint, 4 studs from the target's body.
			local result = validate(wielded, active, target, segment, Vector3.new(0, 0, -4))

			expect(result).to.equal(nil)
		end)

		it("rejects a target outside weapon reach", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -20), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -19))
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(nil)
		end)

		it("does not treat non-collidable parts as cover", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local wall = make_wall(Vector3.new(0, 0, -4.5), created)
			wall.CanCollide = false
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(target:FindFirstChildOfClass("Humanoid"))
		end)

		it("does not treat a bystander character as cover", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			make_character("Bystander", Vector3.new(0, 0, -4.5), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local result = validate(wielded, active, target, segment, target.HumanoidRootPart.Position)

			expect(result).to.equal(target:FindFirstChildOfClass("Humanoid"))
		end)
	end)
end
