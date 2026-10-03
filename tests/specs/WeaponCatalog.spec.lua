local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

return function()
	describe("Weapon Catalog", function()
		it("loads the built-in melee weapon definitions", function()
			local fists = Catalog.Get("Fists")
			local katana = Catalog.Get("Katana")

			expect(fists).to.be.ok()
			expect(katana).to.be.ok()
			expect(Catalog.IsMelee(fists)).to.equal(true)
			expect(Catalog.IsMelee(katana)).to.equal(true)
		end)

		it("returns validated definitions", function()
			expect(Validator.validate(Catalog.Get("Fists"))).to.equal(true)
			expect(Validator.validate(Catalog.Get("Katana"))).to.equal(true)
		end)

		it("returns the same cached definition on every lookup", function()
			expect(Catalog.Get("Fists")).to.equal(Catalog.Get("Fists"))
		end)

		it("returns nil for invalid or unknown identifiers", function()
			expect(Catalog.Get("")).to.equal(nil)
			expect(Catalog.Get("MissingWeapon")).to.equal(nil)
			expect(Catalog.Get(123)).to.equal(nil)
		end)

		it("never returns sibling support modules as weapons", function()
			expect(Catalog.Get("Catalog")).to.equal(nil)
			expect(Catalog.Get("Validator")).to.equal(nil)
			expect(Catalog.Get("CombatConfig")).to.equal(nil)
		end)

		it("only classifies explicit melee definitions as melee", function()
			expect(Catalog.IsMelee({ Type = "Melee" })).to.equal(true)
			expect(Catalog.IsMelee({ Type = "Ranged" })).to.equal(false)
			expect(Catalog.IsMelee(nil)).to.equal(false)
		end)
	end)
end
