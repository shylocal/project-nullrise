local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)
local ParkourController = require(Controllers.ParkourController)
local State = require(Controllers.ParkourController.State)
local VaultTraversal = require(Controllers.ParkourController.VaultTraversal)

local function make_fixture()
	local character = Instance.new("Model")
	character.Name = "VaultTopHopSpecCharacter"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = character
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	local input = {
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
	}
	function input:IsDown()
		return false
	end
	local movement = {}
	function movement:IsSprinting()
		return false
	end
	local state = CharacterState.new({ policy = Policy })
	local controller = ParkourController.new({
		character = character,
		input = input,
		movement = movement,
		state = state,
	})

	return {
		Controller = controller,
		Character = character,
		Humanoid = humanoid,
		Input = input,
		State = state,
	}
end

local function destroy_fixture(fixture)
	fixture.Controller:Destroy()
	fixture.State:Destroy()
	fixture.Input.ActionBegan:Destroy()
	fixture.Input.ActionEnded:Destroy()
	fixture.Character:Destroy()
end

return function()
	describe("Vault top-hop jump restore", function()
		it("restores the native jump setting while keeping the hop guard", function()
			local fixture = make_fixture()
			local controller = fixture.Controller
			local humanoid = fixture.Humanoid
			humanoid.UseJumpPower = true
			humanoid.JumpPower = 50

			expect(VaultTraversal.start_top_hop(controller)).to.equal(true)
			expect(humanoid.JumpPower).to.equal(0)
			local connection = State.resources(controller).Connection
			expect(connection).to.be.ok()

			VaultTraversal.restore_top_hop_jump(controller)

			expect(humanoid.JumpPower).to.equal(50)
			expect(connection.Connected).to.equal(false)
			-- The record and lease stay until landing so they still block re-vaults.
			expect(State.top_hop(controller)).to.be.ok()
			expect(fixture.State:IsActive("TopHop")).to.equal(true)
			expect(fixture.State:CanStart("Vault")).to.equal(false)

			destroy_fixture(fixture)
		end)

		it("does not overwrite jump settings changed after the restore", function()
			local fixture = make_fixture()
			local controller = fixture.Controller
			local humanoid = fixture.Humanoid
			humanoid.UseJumpPower = false
			humanoid.JumpHeight = 7.2

			VaultTraversal.start_top_hop(controller)
			expect(humanoid.JumpHeight).to.equal(0)
			VaultTraversal.restore_top_hop_jump(controller)
			expect(math.abs(humanoid.JumpHeight - 7.2) < 1e-4).to.equal(true)
			humanoid.JumpHeight = 10
			VaultTraversal.finish_top_hop(controller, true)

			expect(humanoid.JumpHeight).to.equal(10)
			expect(State.top_hop(controller)).to.equal(nil)
			expect(fixture.State:IsActive("TopHop")).to.equal(false)

			destroy_fixture(fixture)
		end)

		it("restores jump when the hop finishes before the launch state ended", function()
			local fixture = make_fixture()
			local controller = fixture.Controller
			local humanoid = fixture.Humanoid
			humanoid.UseJumpPower = true
			humanoid.JumpPower = 50

			VaultTraversal.start_top_hop(controller)
			VaultTraversal.finish_top_hop(controller, false)

			expect(humanoid.JumpPower).to.equal(50)
			expect(State.top_hop(controller)).to.equal(nil)
			expect(fixture.State:IsActive("TopHop")).to.equal(false)

			destroy_fixture(fixture)
		end)

		it("ends the hop and restores jump when the controller releases or is destroyed", function()
			local fixture = make_fixture()
			local controller = fixture.Controller
			local humanoid = fixture.Humanoid
			humanoid.UseJumpPower = true
			humanoid.JumpPower = 50

			VaultTraversal.start_top_hop(controller)
			controller:_release()
			expect(State.top_hop(controller)).to.equal(nil)
			expect(humanoid.JumpPower).to.equal(50)

			VaultTraversal.start_top_hop(controller)
			controller:Destroy()
			expect(humanoid.JumpPower).to.equal(50)
			expect(fixture.State:IsActive("TopHop")).to.equal(false)

			destroy_fixture(fixture)
		end)

		it("refuses a vault while a top-hop is in flight", function()
			local fixture = make_fixture()
			VaultTraversal.start_top_hop(fixture.Controller)
			expect(VaultTraversal.try_vault(fixture.Controller)).to.equal(false)
			destroy_fixture(fixture)
		end)
	end)
end
