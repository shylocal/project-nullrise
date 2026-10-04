local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)
local ParkourController = require(Controllers.ParkourController)
local State = require(Controllers.ParkourController.State)

local function vaulting(duration, obstacle)
	return {
		kind = "Vaulting",
		data = {
			ExitVelocity = Vector3.zero,
			Start = CFrame.new(),
			Target = CFrame.new(0, 0, -4),
			Elapsed = 0,
			Duration = duration,
			ArcHeight = 1,
			ArcPeakProgress = 0.5,
			Obstacle = obstacle,
		},
	}
end

return function()
	describe("Parkour state data ownership", function()
		local character
		local input
		local state
		local controller
		local obstacle

		beforeEach(function()
			character = Instance.new("Model")
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Anchored = true
			root.Parent = character
			Instance.new("Humanoid").Parent = character
			input = { ActionBegan = Signal.new(), ActionEnded = Signal.new() }
			function input:IsDown()
				return false
			end
			local movement = {}
			function movement:IsSprinting()
				return false
			end
			state = CharacterState.new({ policy = Policy })
			controller = ParkourController.new({
				character = character,
				input = input,
				movement = movement,
				state = state,
			})
			obstacle = Instance.new("Part")
		end)

		afterEach(function()
			controller:Destroy()
			state:Destroy()
			input.ActionBegan:Destroy()
			input.ActionEnded:Destroy()
			character:Destroy()
			obstacle:Destroy()
		end)

		it("starts Grounded with no state data", function()
			expect(State.kind(controller)).to.equal("Grounded")
			expect(State.hang(controller)).to.equal(nil)
			expect(State.mantle(controller)).to.equal(nil)
			expect(State.vault(controller)).to.equal(nil)
			expect(State.top_hop(controller)).to.equal(nil)
		end)

		it("stores and replaces per-state data records", function()
			local first = vaulting(1, obstacle)
			expect(State.enter(controller, first)).to.equal(true)
			expect(State.vault(controller)).to.equal(first.data)
			expect((State.vault(controller) :: any).Duration).to.equal(1)

			local second = vaulting(2, obstacle)
			expect(State.enter(controller, second)).to.equal(true)
			expect(State.vault(controller)).to.equal(second.data)
			expect((State.vault(controller) :: any).Duration).to.equal(2)
			-- A same-kind transition keeps the state's lease.
			expect(state:IsActive("Vault")).to.equal(true)
		end)

		it("clears one state's data without disturbing a record that is kept", function()
			local top_hop = { StartedAt = 123, SawAir = false }
			expect(State.enter(controller, { kind = "Grounded", TopHop = top_hop })).to.equal(true)
			top_hop.SawAir = true
			expect(State.enter(controller, { kind = "Grounded", TopHop = top_hop })).to.equal(true)

			expect((State.top_hop(controller) :: any).StartedAt).to.equal(123)
			expect((State.top_hop(controller) :: any).SawAir).to.equal(true)
			expect(state:IsActive("TopHop")).to.equal(true)

			expect(State.enter(controller, { kind = "Grounded" })).to.equal(true)
			expect(State.top_hop(controller)).to.equal(nil)
			expect(state:IsActive("TopHop")).to.equal(false)
		end)

		it("clears every state record and resource on reset", function()
			expect(State.enter(controller, vaulting(1, obstacle))).to.equal(true)

			State.reset(controller)

			expect(State.kind(controller)).to.equal("Grounded")
			expect(State.vault(controller)).to.equal(nil)
			expect(state:IsActive("Vault")).to.equal(false)
			expect((next(State.resources(controller)))).to.equal(nil)
		end)

		it("rejects transitions the table does not allow and keeps the current state", function()
			expect(State.enter(controller, vaulting(1, obstacle))).to.equal(true)
			expect(State.enter(controller, {
				kind = "Hanging",
				data = {
					CurrentClimbable = obstacle,
					Normal = Vector3.xAxis,
					HangDepthOffset = Vector3.xAxis,
					HangPosition = Vector3.zero,
				},
			})).to.equal(false)
			expect(State.kind(controller)).to.equal("Vaulting")
			expect(state:IsActive("Hang")).to.equal(false)
		end)
	end)
end
