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

	describe("Move kinds", function()
		it("treats only Charge moves as charges", function()
			expect(AttackLifecycle.is_charge({ Kind = "Charge" })).to.equal(true)
			expect(AttackLifecycle.is_charge({ Kind = "Light" })).to.equal(false)
			expect(AttackLifecycle.is_charge(nil)).to.equal(false)
		end)
	end)

	describe("Hitbox reuse", function()
		local function make_controller()
			local character = Instance.new("Model")
			local wielded = Instance.new("Part")
			wielded.Name = "SpecWielded"
			wielded.Parent = character
			local controller = {
				WeaponController = { Character = character },
				Hitboxes = {},
				HitboxOwners = {},
				ActiveHit = nil,
			}
			return controller, character, wielded
		end

		it("creates one hitbox per wielded part and reuses it", function()
			local controller, character, wielded = make_controller()

			local first = AttackLifecycle.hitbox_for(controller, wielded)
			local second = AttackLifecycle.hitbox_for(controller, wielded)

			expect(first).to.equal(second)
			expect(controller.Hitboxes[wielded]).to.equal(first)

			AttackLifecycle.destroy_hitboxes(controller)
			expect((next(controller.Hitboxes))).to.equal(nil)
			character:Destroy()
		end)

		it("drops hitboxes whose part left the character", function()
			local controller, character, wielded = make_controller()
			AttackLifecycle.hitbox_for(controller, wielded)

			wielded.Parent = nil
			local replacement = Instance.new("Part")
			replacement.Parent = character
			AttackLifecycle.hitbox_for(controller, replacement)

			expect(controller.Hitboxes[wielded]).to.equal(nil)
			expect(controller.Hitboxes[replacement]).to.be.ok()

			AttackLifecycle.destroy_hitboxes(controller)
			wielded:Destroy()
			character:Destroy()
		end)

		it("stops the started hitbox once", function()
			local stops = 0
			local controller = {
				ActiveHit = {
					Hitbox = {
						Stop = function()
							stops += 1
						end,
					},
				},
			}

			AttackLifecycle.stop_hitbox(controller)
			AttackLifecycle.stop_hitbox(controller)

			expect(stops).to.equal(1)
			expect(controller.ActiveHit).to.equal(nil)
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
