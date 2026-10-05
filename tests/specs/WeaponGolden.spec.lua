--!strict
-- Golden values: the schema v2 conversion of Fists and Katana must keep every
-- feel-critical number of the pre-move definitions (Attacks[1], Attacks[2] and
-- Charge became Light1, Light2 and Heavy), except the light-attack Cooldown and
-- MinDuration, which a user decision raised (Fists 0.3 -> 0.35, Katana 0.35 -> 0.6).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

local FIELDS = { "Kind", "Hitbox", "Damage", "Cooldown", "MinDuration", "HitStartAt", "HitWindow", "HitPositionTolerance", "Range" }

-- { Kind, Hitbox, Damage, Cooldown, MinDuration, HitStartAt, HitWindow, Tolerance, Range }
local GOLDEN: { [string]: { [string]: { any } } } = {
	Fists = {
		Light1 = { "Light", "RightFist", 10, 0.35, 0.35, 0.1, 0.55, 3, 8 },
		Light2 = { "Light", "LeftFist", 10, 0.35, 0.35, 0.1, 0.55, 3, 8 },
		Heavy = { "Charge", "RightFist", 20, 0.6, 0.6, 0.15, 0.55, 3, 8 },
	},
	Katana = {
		Light1 = { "Light", "Mesh", 15, 0.6, 0.6, 0.1, 0.55, 3, 10 },
		Light2 = { "Light", "Mesh", 15, 0.6, 0.6, 0.1, 0.55, 3, 10 },
		Heavy = { "Charge", "Mesh", 30, 0.6, 0.6, 0.15, 0.55, 3, 10 },
	},
}

-- { Id, Priority, Looped, TransitionTime }
local ANIMATIONS: { [string]: { [string]: { any } } } = {
	Fists = {
		Equip = { "rbxassetid://13012702135", Enum.AnimationPriority.Action, false, nil },
		Idle = { "rbxassetid://13012725349", Enum.AnimationPriority.Idle, true, nil },
		Sprint = { "rbxassetid://13206474077", Enum.AnimationPriority.Movement, true, 0.325 },
		Light1 = { "rbxassetid://13012786136", Enum.AnimationPriority.Action, false, nil },
		Light2 = { "rbxassetid://13012922268", Enum.AnimationPriority.Action, false, nil },
		Heavy = { "rbxassetid://13013063082", Enum.AnimationPriority.Action, false, 0.275 },
	},
	Katana = {
		Equip = { "rbxassetid://14148916157", Enum.AnimationPriority.Action, false, nil },
		Idle = { "rbxassetid://14149034454", Enum.AnimationPriority.Idle, true, nil },
		Sprint = { "rbxassetid://14149034454", Enum.AnimationPriority.Movement, true, 0.325 },
		Light1 = { "rbxassetid://14148902740", Enum.AnimationPriority.Action, false, nil },
		Light2 = { "rbxassetid://14148910201", Enum.AnimationPriority.Action, false, nil },
		Heavy = { "rbxassetid://14148935586", Enum.AnimationPriority.Action, false, 0.275 },
	},
}

return function()
	-- Defined inside the spec function so TestEZ's injected `expect` is in scope.
	local function expect_animation(animation: any, values: { any })
		expect(animation.Id).to.equal(values[1])
		expect(animation.Priority).to.equal(values[2])
		expect(animation.Looped).to.equal(values[3])
		expect(animation.TransitionTime).to.equal(values[4])
	end

	describe("Weapon golden values", function()
		for weapon_id, moves in pairs(GOLDEN) do
			local current_weapon_id = weapon_id
			local current_moves = moves

			it("keeps every " .. current_weapon_id .. " move number unchanged", function()
				local weapon = Catalog.Get(current_weapon_id) :: any
				assert(weapon, "weapon must exist")

				local count = 0
				for _ in pairs(weapon.Moves) do
					count += 1
				end
				expect(count).to.equal(3)

				for name, values in pairs(current_moves) do
					local move = weapon.Moves[name]
					assert(move, ("%s.%s must exist"):format(current_weapon_id, name))
					for index, field in ipairs(FIELDS) do
						expect(move[field]).to.equal(values[index])
					end
					expect(move.CanSprintWhileAttacking).to.equal(nil)
				end

				local heavy = weapon.Moves.Heavy
				expect(heavy.Hold.HoldTime).to.equal(0.15)
				expect(heavy.Hold.MaxHoldTime).to.equal(10)
				expect(weapon.Moves.Light1.Hold).to.equal(nil)
				expect(weapon.Moves.Light2.Hold).to.equal(nil)
				expect(weapon.CanSprintWhileAttacking).to.equal(true)
			end)

			it("keeps " .. current_weapon_id .. " combo and bindings", function()
				local weapon = Catalog.Get(current_weapon_id) :: any
				expect(#weapon.Combo).to.equal(2)
				expect(weapon.Combo[1]).to.equal("Light1")
				expect(weapon.Combo[2]).to.equal("Light2")
				expect(weapon.Bindings.Primary.Tap).to.equal("Combo")
				expect(weapon.Bindings.Primary.Hold).to.equal("Heavy")
				expect(weapon.Moves.Heavy.Id).to.equal(1)
				expect(weapon.Moves.Light1.Id).to.equal(2)
				expect(weapon.Moves.Light2.Id).to.equal(3)
			end)

			it("keeps " .. current_weapon_id .. " animations verbatim", function()
				local weapon = Catalog.Get(current_weapon_id) :: any
				local expected = ANIMATIONS[current_weapon_id]
				for _, role in ipairs({ "Equip", "Idle", "Sprint" }) do
					expect_animation(weapon.Animations[role], expected[role])
				end
				expect(weapon.Animations.Charge).to.equal(nil)
				for _, name in ipairs({ "Light1", "Light2", "Heavy" }) do
					expect_animation(weapon.Moves[name].Animation, expected[name])
				end
			end)
		end

		it("keeps the Fists wield parts", function()
			local fists = Catalog.Get("Fists") :: any
			expect(fists.Wield.RightFist).to.equal("Right Arm")
			expect(fists.Wield.LeftFist).to.equal("Left Arm")
			local katana = Catalog.Get("Katana") :: any
			expect(katana.Wield.Handle).to.equal("Right Arm")
		end)
	end)
end
