--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CharacterQuery = require(ReplicatedStorage.shared.combat.CharacterQuery)

local function make_character(parent: Instance?): (Model, Humanoid, BasePart)
	local character = Instance.new("Model")
	character.Name = "Character"
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	local arm = Instance.new("Part")
	arm.Name = "Right Arm"
	arm.Parent = character
	character.Parent = parent
	return character, humanoid, arm
end

return function()
	describe("CharacterQuery.resolve", function()
		local created: { Instance }

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		it("resolves a body part and the character model itself", function()
			local character, humanoid, arm = make_character()
			table.insert(created, character)
			local model, found = CharacterQuery.resolve(arm)
			expect(model).to.equal(character)
			expect(found).to.equal(humanoid)
			expect((CharacterQuery.resolve(character))).to.equal(character)
		end)

		it("resolves parts of a nested weapon model to the holder", function()
			local character, humanoid = make_character()
			table.insert(created, character)
			local weapon = Instance.new("Model")
			weapon.Name = "Katana"
			weapon.Parent = character
			local sheath = Instance.new("Model")
			sheath.Parent = weapon
			local blade = Instance.new("Part")
			blade.Parent = sheath
			local hitpoint = Instance.new("Attachment")
			hitpoint.Parent = blade

			for _, instance in ipairs({ weapon, sheath, blade, hitpoint } :: { Instance }) do
				local model, found = CharacterQuery.resolve(instance)
				expect(model).to.equal(character)
				expect(found).to.equal(humanoid)
			end
		end)

		it("resolves characters inside a map container model", function()
			local map = Instance.new("Model")
			table.insert(created, map)
			local wall = Instance.new("Part")
			wall.Parent = map
			local character, humanoid, arm = make_character(map)

			local model, found = CharacterQuery.resolve(wall)
			expect(model).to.equal(nil)
			expect(found).to.equal(nil)

			model, found = CharacterQuery.resolve(arm)
			expect(model).to.equal(character)
			expect(found).to.equal(humanoid)
		end)

		it("returns nil for loose parts and nil input", function()
			local part = Instance.new("Part")
			table.insert(created, part)
			expect((CharacterQuery.resolve(part))).to.equal(nil)
			expect((CharacterQuery.resolve(nil))).to.equal(nil)
		end)

		it("ignores health in resolve but not in resolve_alive", function()
			local character, humanoid, arm = make_character()
			table.insert(created, character)
			expect((CharacterQuery.resolve_alive(arm))).to.equal(character)

			humanoid.Health = 0
			expect((CharacterQuery.resolve(arm))).to.equal(character)
			expect(CharacterQuery.is_alive(humanoid)).to.equal(false)
			local model, found = CharacterQuery.resolve_alive(arm)
			expect(model).to.equal(nil)
			expect(found).to.equal(nil)
		end)
	end)

	describe("CharacterQuery.is_alive", function()
		it("requires a parented humanoid with health", function()
			expect(CharacterQuery.is_alive(nil)).to.equal(false)
			local humanoid = Instance.new("Humanoid")
			expect(CharacterQuery.is_alive(humanoid)).to.equal(false)
			local model = Instance.new("Model")
			humanoid.Parent = model
			expect(CharacterQuery.is_alive(humanoid)).to.equal(true)
			model:Destroy()
		end)
	end)
end
