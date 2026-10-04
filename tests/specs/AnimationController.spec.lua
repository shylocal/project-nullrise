--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local AnimationController = require(StarterPlayer.StarterPlayerScripts.client.controllers.AnimationController)

return function()
	describe("AnimationController CacheReset", function()
		it("fires only when an existing Animator is replaced", function()
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			local first = Instance.new("Animator")
			first.Parent = humanoid

			local controller = AnimationController.new({ character = character })
			local resets = 0
			controller.CacheReset:Connect(function()
				resets += 1
			end)
			expect(controller.Animator).to.equal(first)

			-- The same Animator again is a no-op.
			controller:_set_animator(first)
			expect(resets).to.equal(0)

			-- Not parented, so no deferred ChildAdded re-enters _set_animator.
			local second = Instance.new("Animator")
			controller:_set_animator(second)
			expect(controller.Animator).to.equal(second)
			expect(resets).to.equal(1)

			controller:Destroy()
			second:Destroy()
			character:Destroy()
		end)
	end)
end
