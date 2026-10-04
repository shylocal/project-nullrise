--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.shared.config)
local Envelope = require(ReplicatedStorage.shared.config.Envelope)
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)

local GRAVITY = 196.2

local function near(a: number, b: number, epsilon: number?): boolean
	return math.abs(a - b) <= (epsilon or 1e-6)
end

return function()
	describe("Movement envelope", function()
		local limits = Envelope.compute(Config.Movement, Config.Parkour, GRAVITY)

		it("fits every motion source inside the computed limits", function()
			for name, source in pairs(limits.Sources) do
				if source.Horizontal ~= nil then
					expect(source.Horizontal > 0).to.equal(true)
					if source.Horizontal > limits.MaxHorizontalSpeed then
						error(("%s horizontal %.2f exceeds %.2f"):format(name, source.Horizontal, limits.MaxHorizontalSpeed))
					end
				end
				if source.Upward ~= nil then
					expect(source.Upward > 0).to.equal(true)
					if source.Upward > limits.MaxUpwardSpeed then
						error(("%s upward %.2f exceeds %.2f"):format(name, source.Upward, limits.MaxUpwardSpeed))
					end
				end
			end
		end)

		it("derives the documented limits from today's tuning", function()
			-- Vault: (24 + 12) / 0.95 = 37.89 is the fastest horizontal source.
			expect(near(limits.Sources.Vault.Horizontal :: number, 36 / 0.95)).to.equal(true)
			expect(near(limits.MaxHorizontalSpeed, 2.6 * 36 / 0.95)).to.equal(true)
			expect(near(limits.MaxHorizontalSpeed, 98.5, 0.05)).to.equal(true)
			-- Native jump (50) is the fastest upward source: 4.8 * 50 = 240, unchanged.
			expect(near(limits.MaxUpwardSpeed, 240)).to.equal(true)
			expect(limits.MaxDownwardSpeed).to.equal(240)
			expect(limits.TeleportDistance).to.equal(40)
		end)

		it("lists every source", function()
			for _, name in ipairs({ "Walk", "Sprint", "Vault", "VaultExit", "TopHop", "Traverse", "Mantle", "Jump" }) do
				expect(limits.Sources[name]).to.be.ok()
			end
		end)

		it("raises the limit when a source gets faster", function()
			local movement = Freeze.clone_deep(Config.Movement) :: any
			movement.SprintSpeed *= 2
			local faster = Envelope.compute(movement, Config.Parkour, GRAVITY)
			expect(faster.MaxHorizontalSpeed > limits.MaxHorizontalSpeed).to.equal(true)

			movement = Freeze.clone_deep(Config.Movement) :: any
			movement.MaxJumpVelocity = 80
			local higher = Envelope.compute(movement, Config.Parkour, GRAVITY)
			expect(higher.MaxUpwardSpeed > limits.MaxUpwardSpeed).to.equal(true)
		end)

		it("scales the top-hop launch with gravity", function()
			local heavy = Envelope.compute(Config.Movement, Config.Parkour, GRAVITY * 4)
			expect(heavy.Sources.TopHop.Upward :: number > limits.Sources.TopHop.Upward :: number).to.equal(true)
		end)

		it("rejects a non-positive gravity", function()
			expect(function()
				Envelope.compute(Config.Movement, Config.Parkour, 0)
			end).to.throw()
		end)
	end)
end
