local StarterPlayer = game:GetService("StarterPlayer")

local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local AttackLifecycle = require(Controllers.CombatController.AttackLifecycle)

return function()
	describe("Combat attack callback ownership", function()
		it("accepts callbacks owned by the current attack lifecycle", function()
			local attack_trove = {}
			local controller = {
				AttackTrove = attack_trove,
				AttackLifecycleId = 7,
			}

			expect(AttackLifecycle.is_current_attack(controller, attack_trove, 7)).to.equal(true)
		end)

		it("rejects callbacks after the active attack trove is replaced", function()
			local stale_trove = {}
			local controller = {
				AttackTrove = {},
				AttackLifecycleId = 8,
			}

			expect(AttackLifecycle.is_current_attack(controller, stale_trove, 8)).to.equal(false)
		end)

		it("rejects callbacks from an earlier generation after reset", function()
			local attack_trove = {}
			local controller = {
				AttackTrove = attack_trove,
				AttackLifecycleId = 10,
			}

			controller.AttackLifecycleId += 1

			expect(AttackLifecycle.is_current_attack(controller, attack_trove, 10)).to.equal(false)
			expect(AttackLifecycle.is_current_attack(controller, attack_trove, 11)).to.equal(true)
		end)
	end)

	describe("Attack sprint rule", function()
		local function controller_with(weapon_can_sprint)
			return { WeaponController = { Equipped = { CanSprintWhileAttacking = weapon_can_sprint } } }
		end

		it("uses the weapon rule when the attack does not override it", function()
			expect(AttackLifecycle.can_sprint_while_attacking(controller_with(true), {})).to.equal(true)
			expect(AttackLifecycle.can_sprint_while_attacking(controller_with(false), {})).to.equal(false)
		end)

		it("lets the attack override the weapon rule", function()
			expect(AttackLifecycle.can_sprint_while_attacking(controller_with(true), { CanSprintWhileAttacking = false })).to.equal(false)
			expect(AttackLifecycle.can_sprint_while_attacking(controller_with(false), { CanSprintWhileAttacking = true })).to.equal(true)
		end)
	end)

	describe("Attack lease", function()
		it("releases the held lease once", function()
			local releases = 0
			local controller = {
				AttackLease = {
					Release = function()
						releases += 1
					end,
				},
			}

			AttackLifecycle.release_lease(controller)
			AttackLifecycle.release_lease(controller)

			expect(releases).to.equal(1)
			expect(controller.AttackLease).to.equal(nil)
		end)
	end)
end
