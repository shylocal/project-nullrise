local StarterPlayer = game:GetService("StarterPlayer")

local HumanoidOverrides = require(StarterPlayer.StarterPlayerScripts.client.controllers.CharacterState.HumanoidOverrides)

return function()
	describe("HumanoidOverrides", function()
		local character
		local humanoid
		local overrides

		beforeEach(function()
			character = Instance.new("Model")
			humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			overrides = HumanoidOverrides.new(humanoid)
		end)

		afterEach(function()
			overrides:Destroy()
			character:Destroy()
		end)

		it("applies a pushed value and restores the base when popped", function()
			local handle = overrides:Push("Hang", { AutoRotate = false, PlatformStand = true })
			expect(humanoid.AutoRotate).to.equal(false)
			expect(humanoid.PlatformStand).to.equal(true)
			expect(overrides:Base("AutoRotate")).to.equal(true)

			handle:Pop()
			expect(humanoid.AutoRotate).to.equal(true)
			expect(humanoid.PlatformStand).to.equal(false)
		end)

		it("keeps the most recent live handle's value in effect", function()
			humanoid.HipHeight = 2
			local first = overrides:Push("A", { HipHeight = 1 })
			local second = overrides:Push("B", { HipHeight = 0.5 })
			expect(humanoid.HipHeight).to.equal(0.5)

			-- Popping a handle that is not on top leaves the top value in effect.
			first:Pop()
			expect(humanoid.HipHeight).to.equal(0.5)
			expect(overrides:Base("HipHeight")).to.equal(2)

			second:Pop()
			expect(humanoid.HipHeight).to.equal(2)
		end)

		it("falls back to the next handle when the top one is popped", function()
			humanoid.HipHeight = 2
			local first = overrides:Push("A", { HipHeight = 1 })
			local second = overrides:Push("B", { HipHeight = 0.5 })
			second:Pop()
			expect(humanoid.HipHeight).to.equal(1)
			first:Pop()
			expect(humanoid.HipHeight).to.equal(2)
		end)

		it("writes Set through only for the top handle", function()
			humanoid.HipHeight = 2
			local first = overrides:Push("A", { HipHeight = 1 })
			first:Set("HipHeight", 1.5)
			expect(humanoid.HipHeight).to.equal(1.5)

			local second = overrides:Push("B", { HipHeight = 0.5 })
			first:Set("HipHeight", 1.25)
			expect(humanoid.HipHeight).to.equal(0.5)
			second:Pop()
			expect(humanoid.HipHeight).to.equal(1.25)
			first:Pop()
		end)

		it("rejects Set for a property the handle did not push", function()
			local handle = overrides:Push("A", { AutoRotate = false })
			expect(function()
				handle:Set("HipHeight", 1)
			end).to.throw()
			handle:Pop()
		end)

		it("maps JumpingEnabled to the Jumping state", function()
			local jumping = Enum.HumanoidStateType.Jumping
			local handle = overrides:Push("Mantle", { JumpingEnabled = false })
			expect(humanoid:GetStateEnabled(jumping)).to.equal(false)
			expect(overrides:Base("JumpingEnabled")).to.equal(true)
			handle:Pop()
			expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		end)

		it("makes Pop idempotent", function()
			local outer = overrides:Push("A", { AutoRotate = false })
			local inner = overrides:Push("B", { AutoRotate = false })
			inner:Pop()
			inner:Pop()
			expect(humanoid.AutoRotate).to.equal(false)
			outer:Pop()
			expect(humanoid.AutoRotate).to.equal(true)
		end)

		it("reports the current value as the base when nothing overrides it", function()
			humanoid.JumpPower = 42
			expect(overrides:Base("JumpPower")).to.equal(42)
		end)

		it("does not write the base back to an unparented Humanoid", function()
			local handle = overrides:Push("A", { AutoRotate = false })
			humanoid.Parent = nil
			handle:Pop()
			expect(humanoid.AutoRotate).to.equal(false)
			humanoid.Parent = character
		end)

		it("rejects unsupported properties", function()
			expect(function()
				overrides:Push("A", { WalkSpeed = 30 } :: any)
			end).to.throw()
		end)

		it("pops everything on Destroy", function()
			humanoid.JumpPower = 50
			overrides:Push("A", { JumpPower = 0, AutoRotate = false })
			overrides:Push("B", { JumpPower = 10 })
			overrides:Destroy()
			expect(humanoid.JumpPower).to.equal(50)
			expect(humanoid.AutoRotate).to.equal(true)
		end)
	end)
end
