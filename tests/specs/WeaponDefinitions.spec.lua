local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

local function is_finite_number(value)
	return typeof(value) == "number" and math.isfinite(value)
end

local function expect_animation(animation, expect_fn)
	expect_fn(typeof(animation)).to.equal("table")
	expect_fn(typeof(animation.Id)).to.equal("string")
	expect_fn(string.match(animation.Id, "^rbxassetid://%d+$") ~= nil).to.equal(true)
	expect_fn(animation.Priority ~= nil).to.equal(true)
	expect_fn(typeof(animation.Looped)).to.equal("boolean")
end

local function expect_attack(attack, expect_fn)
	expect_fn(typeof(attack)).to.equal("table")
	expect_fn(typeof(attack.Hitbox)).to.equal("string")
	expect_fn(attack.Hitbox ~= "").to.equal(true)
	expect_fn(is_finite_number(attack.Damage) and attack.Damage > 0).to.equal(true)
	expect_fn(is_finite_number(attack.Cooldown) and attack.Cooldown >= 0).to.equal(true)
	expect_fn(is_finite_number(attack.Range) and attack.Range > 0).to.equal(true)
	expect_fn(is_finite_number(attack.HitPositionTolerance) and attack.HitPositionTolerance >= 0).to.equal(true)
	expect_fn(is_finite_number(attack.HitStartAt) and attack.HitStartAt >= 0).to.equal(true)
	expect_fn(is_finite_number(attack.HitWindow) and attack.HitWindow > 0).to.equal(true)
	expect_fn(is_finite_number(attack.MinDuration) and attack.MinDuration > 0).to.equal(true)
	-- The client cooldown must never let a legitimate client start an attack
	-- before the server-enforced MinDuration.
	expect_fn(attack.Cooldown >= attack.MinDuration).to.equal(true)
	expect_animation(attack.Animation, expect_fn)
end

return function()
	describe("Built-in weapon definitions", function()
		for _, weapon_id in ipairs({ "Fists", "Katana" }) do
			local current_weapon_id = weapon_id
			it("keeps " .. current_weapon_id .. " structurally valid", function()
				local weapon = Catalog.Get(current_weapon_id)

				expect(typeof(weapon)).to.equal("table")
				expect(weapon.Type).to.equal("Melee")
				expect(typeof(weapon.Model)).to.equal("string")
				expect(weapon.Model ~= "").to.equal(true)
				expect(typeof(weapon.CanSprintWhileAttacking)).to.equal("boolean")
				expect(typeof(weapon.Wield)).to.equal("table")
				expect(next(weapon.Wield) ~= nil).to.equal(true)
				for wield_name, body_part in pairs(weapon.Wield) do
					expect(typeof(wield_name)).to.equal("string")
					expect(wield_name ~= "").to.equal(true)
					expect(typeof(body_part)).to.equal("string")
					expect(body_part ~= "").to.equal(true)
				end

				for _, animation_name in ipairs({ "Equip", "Idle", "Sprint", "Charge" }) do
					expect_animation(weapon.Animations[animation_name], expect)
				end

				expect(typeof(weapon.Attacks)).to.equal("table")
				expect_attack(weapon.Attacks[1], expect)
				expect_attack(weapon.Attacks[2], expect)

				expect(typeof(weapon.Charge)).to.equal("table")
				expect_attack(weapon.Charge, expect)
				expect(is_finite_number(weapon.Charge.HoldTime) and weapon.Charge.HoldTime > 0).to.equal(true)
				expect(is_finite_number(weapon.Charge.MaxHoldTime)).to.equal(true)
				expect(weapon.Charge.MaxHoldTime > weapon.Charge.HitStartAt).to.equal(true)
			end)
		end
	end)
end
