local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Controllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client"):WaitForChild("controllers")
local AttackLifecycle = require(Controllers:WaitForChild("CombatController"):WaitForChild("AttackLifecycle"))

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
end
