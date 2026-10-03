local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local ParkourController = require(Client.controllers.ParkourController)
local ParkourState = require(Client.controllers.ParkourController.State)
local VaultTraversal = require(Client.controllers.ParkourController.VaultTraversal)

local function make_fixture()
	local character = Instance.new("Model")
	character.Name = "ParkourLifecycleSpecCharacter"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	local input = {
		Down = {},
	}
	function input:IsDown(action)
		return self.Down[action] == true
	end

	local movement = {
		SprintBlockCalls = {},
	}
	function movement:SetSprintBlocked(blocked, reason)
		table.insert(self.SprintBlockCalls, {
			Blocked = blocked,
			Reason = reason,
		})
	end

	local controller = setmetatable({
		Character = character,
		Root = root,
		Humanoid = humanoid,
		InputController = input,
		MovementController = movement,
		Trove = Trove.new(),
		State = "Grounded",
		_humanoidSnapshots = {},
		GrabBlockedUntilJumpReleased = false,
		_destroyed = false,
	}, ParkourController)

	return controller, character, humanoid, root, input, movement
end

return function()
	describe("Parkour traversal lifecycle", function()
	local controller
	local character

	beforeEach(function()
		controller, character = make_fixture()
	end)

	afterEach(function()
		if controller then
			controller:Destroy()
			controller = nil
		end
		if character then
			character:Destroy()
			character = nil
		end
	end)

	it("allows only valid traversal state transitions", function()
		expect(ParkourState.transition(controller, "Hanging")).to.equal(true)
		expect(ParkourState.transition(controller, "Mantling")).to.equal(true)
		expect(ParkourState.transition(controller, "Vaulting")).to.equal(false)
		expect(controller.State).to.equal("Mantling")
		expect(ParkourState.transition(controller, "Grounded")).to.equal(true)
		expect(ParkourState.transition(controller, "Unknown")).to.equal(false)
		expect(controller.State).to.equal("Grounded")
	end)

	it("restores the hanging pose and releases its sprint blocker exactly once", function()
		local humanoid = controller.Humanoid
		local movement = controller.MovementController

		expect(ParkourState.transition(controller, "Hanging")).to.equal(true)
		local climbable = Instance.new("Part")
		ParkourState.set_data(controller, "Hanging", {
			CurrentClimbable = climbable,
			Normal = Vector3.xAxis,
			HangDepthOffset = Vector3.xAxis,
			HangPosition = Vector3.new(1, 2, 3),
			CornerLockPosition = Vector3.new(4, 5, 6),
			CornerLockInputDirection = 1,
		})
		ParkourState.capture_humanoid(controller, "Hang", { "AutoRotate", "PlatformStand" })
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true

		controller:_release()
		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(ParkourState.get_data(controller, "Hanging")).to.equal(nil)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(ParkourState.get_humanoid_snapshot(controller, "Hang")).to.equal(nil)
		expect(#movement.SprintBlockCalls).to.equal(1)
		expect(movement.SprintBlockCalls[1].Blocked).to.equal(false)
	end)

	it("updates a vault from stored traversal state and finishes on completion", function()
		local humanoid = controller.Humanoid
		local root = controller.Root
		local jumping = Enum.HumanoidStateType.Jumping

		expect(ParkourState.transition(controller, "Vaulting")).to.equal(true)
		ParkourState.capture_humanoid(controller, "Vault", {
			"AutoRotate",
			"PlatformStand",
			"HipHeight",
			"JumpingEnabled",
		})
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		humanoid:SetStateEnabled(jumping, false)
		ParkourState.set_data(controller, "Vault", {
			Start = CFrame.new(0, 0, 0),
			Target = CFrame.new(0, 2, -4),
			Elapsed = 0,
			Duration = 1,
			ArcHeight = 1,
			ArcPeakProgress = 0.5,
			ExitVelocity = Vector3.new(8, 0, 0),
		})

		expect(VaultTraversal.update_vault(controller, 0.25)).to.equal(true)
		local vault = ParkourState.get_data(controller, "Vault")
		expect(vault.Elapsed).to.equal(0.25)
		expect(math.abs(root.CFrame.Position.Z - (-1)) < 1e-4).to.equal(true)
		expect(ParkourState.get_humanoid_value(controller, "Vault", "JumpingEnabled")).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		expect(VaultTraversal.update_vault(controller, 1)).to.equal(true)
		expect(controller.State).to.equal("Grounded")
		expect(ParkourState.get_data(controller, "Vault")).to.equal(nil)
		expect(ParkourState.get_humanoid_snapshot(controller, "Vault")).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)

		expect(function()
			VaultTraversal.update_vault(controller, 0.1)
		end).never.to.throw()
	end)

	it("restores Jumping and movement properties when a mantle is interrupted", function()
		local humanoid = controller.Humanoid
		local movement = controller.MovementController
		local jumping = Enum.HumanoidStateType.Jumping

		expect(ParkourState.transition(controller, "Hanging")).to.equal(true)
		ParkourState.capture_humanoid(controller, "Hang", { "AutoRotate", "PlatformStand" })
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		expect(ParkourState.transition(controller, "Mantling")).to.equal(true)
		controller.GrabBlockedUntilJumpReleased = true
		ParkourState.capture_humanoid(controller, "Mantle", { "JumpingEnabled" })
		humanoid:SetStateEnabled(jumping, false)
		ParkourState.set_data(controller, "Mantling", {
			Start = CFrame.new(0, 0, 0),
			Target = CFrame.new(0, 4, 0),
			Elapsed = 0.2,
			Duration = 0.35,
		})

		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(ParkourState.get_data(controller, "Mantling")).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(ParkourState.get_humanoid_snapshot(controller, "Mantle")).to.equal(nil)
		expect(ParkourState.get_humanoid_snapshot(controller, "Hang")).to.equal(nil)
		expect(#movement.SprintBlockCalls).to.equal(1)
		expect(movement.SprintBlockCalls[1].Blocked).to.equal(false)
	end)

	it("keeps the vault Jumping snapshot until vault cleanup after Jump is released", function()
		local humanoid = controller.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping

		expect(ParkourState.transition(controller, "Vaulting")).to.equal(true)
		controller.GrabBlockedUntilJumpReleased = true
		ParkourState.capture_humanoid(controller, "Vault", {
			"AutoRotate",
			"PlatformStand",
			"HipHeight",
			"JumpingEnabled",
		})
		humanoid:SetStateEnabled(jumping, false)
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		ParkourState.set_data(controller, "Vault", {
			Start = controller.Root.CFrame,
			Target = controller.Root.CFrame * CFrame.new(0, 0, -5),
			Elapsed = 0,
			Duration = 1,
			ArcHeight = 1,
			ArcPeakProgress = 0.5,
		})
		controller.InputController.Down[Actions.Jump] = false

		controller:_step(0.1)

		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(ParkourState.get_humanoid_value(controller, "Vault", "JumpingEnabled")).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(ParkourState.get_humanoid_snapshot(controller, "Vault")).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
	end)

	it("restores a pending grounded jump lock and makes Destroy idempotent", function()
		local humanoid = controller.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping

		controller.GrabBlockedUntilJumpReleased = true
		ParkourState.capture_humanoid(controller, "Mantle", { "JumpingEnabled" })
		humanoid:SetStateEnabled(jumping, false)

		controller:Destroy()
		local call_count_after_destroy = #controller.MovementController.SprintBlockCalls
		controller:Destroy()

		expect(controller._destroyed).to.equal(true)
		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(ParkourState.get_humanoid_snapshot(controller, "Mantle")).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(#controller.MovementController.SprintBlockCalls).to.equal(call_count_after_destroy)
	end)
	end)
end
