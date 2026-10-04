local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Validator = require(ReplicatedStorage.shared.weapons.Validator)

-- Every catalog weapon passes the full validator. New weapons are covered
-- automatically by looping Catalog.Ids().
return function()
	describe("Weapon content", function()
		for _, weapon_id in ipairs(Catalog.Ids()) do
			local current_weapon_id = weapon_id
			it("keeps " .. current_weapon_id .. " valid", function()
				local errors = Validator.check(Catalog.Get(current_weapon_id), current_weapon_id)
				if #errors > 0 then
					error(table.concat(errors, "\n"), 0)
				end
			end)

			it("keeps " .. current_weapon_id .. " attack cooldowns no shorter than MinDuration", function()
				local weapon = Catalog.Get(current_weapon_id)
				assert(weapon, "weapon must exist")
				for _, attack in ipairs(weapon.Attacks) do
					expect(attack.Cooldown >= attack.MinDuration).to.equal(true)
				end
				if weapon.Charge then
					expect(weapon.Charge.Cooldown >= weapon.Charge.MinDuration).to.equal(true)
					expect(weapon.Charge.MaxHoldTime > weapon.Charge.HitStartAt).to.equal(true)
				end
			end)
		end
	end)
end
