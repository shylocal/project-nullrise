local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local ParkourController = require(Client.controllers.ParkourController)

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

	it("restores the hanging pose and releases its sprint blocker exactly once", function()
		local humanoid = controller.Humanoid
		local movement = controller.MovementController

		controller.State = "Hanging"
		controller.CurrentClimbable = Instance.new("Part")
		controller.Normal = Vector3.xAxis
		controller.HangDepthOffset = Vector3.xAxis
		controller.HangPosition = Vector3.new(1, 2, 3)
		controller.CornerLockPosition = Vector3.new(4, 5, 6)
		controller.CornerLockInputDirection = 1
		controller.AutoRotateBeforeHang = true
		controller.PlatformStandBeforeHang = false
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true

		controller:_release()
		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(controller.CurrentClimbable).to.equal(nil)
		expect(controller.Normal).to.equal(nil)
		expect(controller.HangDepthOffset).to.equal(nil)
		expect(controller.HangPosition).to.equal(nil)
		expect(controller.CornerLockPosition).to.equal(nil)
		expect(controller.CornerLockInputDirection).to.equal(nil)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(#movement.SprintBlockCalls).to.equal(1)
		expect(movement.SprintBlockCalls[1].Blocked).to.equal(false)
	end)

	it("restores Jumping and movement properties when a mantle is interrupted", function()
		local humanoid = controller.Humanoid
		local movement = controller.MovementController
		local jumping = Enum.HumanoidStateType.Jumping

		controller.State = "Mantling"
		controller.GrabBlockedUntilJumpReleased = true
		controller.JumpingEnabledBeforeMantle = true
		humanoid:SetStateEnabled(jumping, false)
		controller.AutoRotateBeforeHang = true
		controller.PlatformStandBeforeHang = false
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		controller._mantleStart = CFrame.new(0, 0, 0)
		controller._mantleTarget = CFrame.new(0, 4, 0)
		controller._mantleElapsed = 0.2
		controller._mantleDuration = 0.35

		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(controller._mantleStart).to.equal(nil)
		expect(controller._mantleTarget).to.equal(nil)
		expect(controller._mantleElapsed).to.equal(nil)
		expect(controller._mantleDuration).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(controller.JumpingEnabledBeforeMantle).to.equal(nil)
		expect(#movement.SprintBlockCalls).to.equal(1)
		expect(movement.SprintBlockCalls[1].Blocked).to.equal(false)
	end)

	it("keeps the vault Jumping snapshot until vault cleanup after Jump is released", function()
		local humanoid = controller.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping

		controller.State = "Vaulting"
		controller.GrabBlockedUntilJumpReleased = true
		controller.VaultJumpingEnabledBefore = true
		humanoid:SetStateEnabled(jumping, false)
		controller.VaultAutoRotateBefore = true
		controller.VaultPlatformStandBefore = false
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		controller._vaultStart = controller.Root.CFrame
		controller._vaultTarget = controller.Root.CFrame * CFrame.new(0, 0, -5)
		controller._vaultElapsed = 0
		controller._vaultDuration = 1
		controller._vaultArcHeight = 1
		controller._vaultArcPeakProgress = 0.5
		controller.InputController.Down[Actions.Jump] = false

		controller:_step(0.1)

		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(controller.VaultJumpingEnabledBefore).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		controller:_release()

		expect(controller.State).to.equal("Grounded")
		expect(controller.VaultJumpingEnabledBefore).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
	end)

	it("restores a pending grounded jump lock and makes Destroy idempotent", function()
		local humanoid = controller.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping

		controller.GrabBlockedUntilJumpReleased = true
		controller.JumpingEnabledBeforeMantle = true
		humanoid:SetStateEnabled(jumping, false)

		controller:Destroy()
		local call_count_after_destroy = #controller.MovementController.SprintBlockCalls
		controller:Destroy()

		expect(controller._destroyed).to.equal(true)
		expect(controller.GrabBlockedUntilJumpReleased).to.equal(false)
		expect(controller.JumpingEnabledBeforeMantle).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(#controller.MovementController.SprintBlockCalls).to.equal(call_count_after_destroy)
	end)
	end)
end
