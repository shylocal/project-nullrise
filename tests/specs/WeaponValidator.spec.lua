local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

return function()
	describe("Weapon definition validator", function()
		it("accepts the built-in melee definitions", function()
			expect(Validator.validate(Catalog.Get("Fists"))).to.equal(true)
			expect(Validator.validate(Catalog.Get("Katana"))).to.equal(true)
		end)

		it("rejects malformed melee definitions", function()
			local fists = Catalog.Get("Fists")
			local invalid = table.clone(fists)
			invalid.Attacks = table.clone(fists.Attacks)
			invalid.Attacks[1] = table.clone(fists.Attacks[1])
			invalid.Attacks[1].HitPositionTolerance = nil

			local valid, reason = Validator.validate(invalid)
			expect(valid).to.equal(false)
			expect(typeof(reason)).to.equal("string")
		end)

		it("does not impose melee-only fields on other weapon types", function()
			expect(Validator.validate({ Type = "Ranged" })).to.equal(true)
		end)

		it("rejects malformed animation identifiers", function()
			local fists = Catalog.Get("Fists")
			local invalid = table.clone(fists)
			invalid.Animations = table.clone(fists.Animations)
			invalid.Animations.Idle = table.clone(fists.Animations.Idle)
			invalid.Animations.Idle.Id = "not-an-asset"

			expect(Validator.validate(invalid)).to.equal(false)
		end)
	end)
end
