--!strict
local StarterPlayer = game:GetService("StarterPlayer")

local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)

return function()
	describe("CharacterState", function()
		local state: CharacterState.CharacterState
		local changes: { { Activity: string, Active: boolean } }

		beforeEach(function()
			state = CharacterState.new({ policy = Policy })
			changes = {}
			state.Changed:Connect(function(activity: string, active: boolean)
				table.insert(changes, { Activity = activity, Active = active })
			end)
		end)

		afterEach(function()
			state:Destroy()
		end)

		it("requires a valid policy", function()
			expect(function()
				CharacterState.new({} :: any)
			end).to.throw()
			expect(function()
				CharacterState.new({ policy = { Attack = {} } })
			end).to.throw()
			local broken = table.clone(Policy)
			broken.Hang = { "Fly" }
			expect(function()
				CharacterState.new({ policy = broken })
			end).to.throw()
		end)

		it("allows every action while nothing is active", function()
			for _, action in { "Attack", "Charge", "Sprint", "Vault", "Grab" } do
				local allowed, blocker = state:CanStart(action :: CharacterState.Action)
				expect(allowed).to.equal(true)
				expect(blocker).to.equal(nil)
			end
		end)

		it("blocks actions according to the policy and reports the blocker", function()
			local lease = state:Acquire("parkour", "Hang")
			local allowed, blocker = state:CanStart("Attack")
			expect(allowed).to.equal(false)
			expect(blocker).to.equal("Hang")
			expect((state:CanStart("Grab"))).to.equal(true)
			lease:Release()
			expect((state:CanStart("Attack"))).to.equal(true)
		end)

		it("does not block anything for a plain Attack, but AttackRooted blocks Sprint", function()
			local attack = state:Acquire("combat", "Attack")
			expect((state:CanStart("Sprint"))).to.equal(true)
			expect((state:CanStart("Attack"))).to.equal(true)
			attack:Release()

			local rooted = state:Acquire("combat", "AttackRooted")
			expect((state:CanStart("Sprint"))).to.equal(false)
			rooted:Release()
		end)

		it("fires Changed only on the first acquire and the last release", function()
			local first = state:Acquire("a", "Vault")
			local second = state:Acquire("b", "Vault")
			expect(#changes).to.equal(1)
			expect(changes[1].Activity).to.equal("Vault")
			expect(changes[1].Active).to.equal(true)

			first:Release()
			expect(#changes).to.equal(1)
			expect(state:IsActive("Vault")).to.equal(true)

			second:Release()
			expect(#changes).to.equal(2)
			expect(changes[2].Active).to.equal(false)
			expect(state:IsActive("Vault")).to.equal(false)
		end)

		it("makes lease release idempotent", function()
			local first = state:Acquire("a", "Stunned")
			local second = state:Acquire("b", "Stunned")
			first:Release()
			first:Release()
			expect(state:IsActive("Stunned")).to.equal(true)
			second:Release()
			expect(state:IsActive("Stunned")).to.equal(false)
		end)

		it("rejects unknown activities and actions", function()
			expect(function()
				-- An activity outside the policy, so the cast is deliberate.
				state:Acquire("a", "Fly" :: any)
			end).to.throw()
			expect(function()
				state:CanStart("Fly" :: any)
			end).to.throw()
		end)

		it("memoises one override stack per Humanoid", function()
			local humanoid = Instance.new("Humanoid")
			local other = Instance.new("Humanoid")
			expect(state:Overrides(humanoid)).to.equal(state:Overrides(humanoid))
			expect(state:Overrides(humanoid) ~= state:Overrides(other)).to.equal(true)
			humanoid:Destroy()
			other:Destroy()
		end)

		it("releases every lease and restores every override on Destroy", function()
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			local other = CharacterState.new({ policy = Policy })
			local released: { string } = {}
			other.Changed:Connect(function(activity: string, active: boolean)
				if not active then
					table.insert(released, activity)
				end
			end)
			other:Acquire("a", "Hang")
			other:Overrides(humanoid):Push("Hang", { AutoRotate = false })
			expect(humanoid.AutoRotate).to.equal(false)

			other:Destroy()
			other:Destroy()

			expect(other:IsActive("Hang")).to.equal(false)
			expect(#released).to.equal(1)
			expect(humanoid.AutoRotate).to.equal(true)
			character:Destroy()
		end)
	end)
end
