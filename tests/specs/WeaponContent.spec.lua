--!strict
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

			it("keeps " .. current_weapon_id .. " move cooldowns no shorter than MinDuration", function()
				local weapon = Catalog.Get(current_weapon_id)
				assert(weapon, "weapon must exist")
				for _, move in pairs(weapon.Moves) do
					expect(move.Cooldown >= move.MinDuration).to.equal(true)
					if move.Kind == "Charge" then
						local hold = move.Hold
						assert(hold, "a Charge move must have Hold")
						expect(hold.MaxHoldTime > move.HitStartAt).to.equal(true)
					end
				end
			end)

			it("keeps every " .. current_weapon_id .. " combo entry a Light move", function()
				local weapon = Catalog.Get(current_weapon_id)
				assert(weapon, "weapon must exist")
				expect(#weapon.Combo >= 1).to.equal(true)
				for _, name in ipairs(weapon.Combo) do
					expect(weapon.Moves[name].Kind).to.equal("Light")
				end
			end)
		end
	end)
end
