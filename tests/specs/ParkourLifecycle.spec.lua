local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)
local ParkourController = require(Controllers.ParkourController)
local ParkourState = require(Controllers.ParkourController.State)
local VaultTraversal = require(Controllers.ParkourController.VaultTraversal)

local function make_input()
	local input = {
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
	}
	function input:IsDown(action)
		return self.Down[action] == true
	end
	function input:Destroy()
		self.ActionBegan:Destroy()
		self.ActionEnded:Destroy()
	end
	return input
end

local function make_fixture()
	local character = Instance.new("Model")
	character.Name = "ParkourLifecycleSpecCharacter"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	local input = make_input()
	local state = CharacterState.new({ policy = Policy })
	local movement = {}
	function movement:IsSprinting()
		return false
	end

	local controller = ParkourController.new({
		character = character,
		input = input,
		movement = movement,
		state = state,
	})

	-- Every activity start/end, in order (replaces the old SetSprintBlocked log).
	local changes = {}
	state.Changed:Connect(function(activity, active)
		table.insert(changes, { Activity = activity, Active = active })
	end)

	return {
		Controller = controller,
		Character = character,
		Root = root,
		Humanoid = humanoid,
		Input = input,
		State = state,
		Changes = changes,
	}
end

local function hanging(climbable)
	return {
		kind = "Hanging",
		data = {
			CurrentClimbable = climbable,
			Normal = Vector3.xAxis,
			HangDepthOffset = Vector3.xAxis,
			HangPosition = Vector3.new(1, 2, 3),
			CornerLockPosition = Vector3.new(4, 5, 6),
			CornerLockInputDirection = 1,
		},
	}
end

local function mantling(elapsed)
	return {
		kind = "Mantling",
		data = {
			Start = CFrame.new(0, 0, 0),
			Target = CFrame.new(0, 4, 0),
			Elapsed = elapsed,
			Duration = 0.35,
		},
	}
end

return function()
	describe("Parkour traversal lifecycle", function()
	local fixture
	local controller
	local climbable

	beforeEach(function()
		fixture = make_fixture()
		controller = fixture.Controller
		climbable = Instance.new("Part")
	end)

	afterEach(function()
		if controller then
			controller:Destroy()
			controller = nil
		end
		fixture.State:Destroy()
		fixture.Input:Destroy()
		fixture.Character:Destroy()
		climbable:Destroy()
		fixture = nil
	end)

	it("requires every constructor dependency", function()
		expect(function()
			ParkourController.new({ character = fixture.Character, input = fixture.Input, state = fixture.State })
		end).to.throw()
	end)

	it("allows only valid traversal state transitions", function()
		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect(ParkourState.enter(controller, mantling(0))).to.equal(true)
		expect(ParkourState.enter(controller, {
			kind = "Vaulting",
			data = {
				ExitVelocity = Vector3.zero,
				Start = CFrame.new(),
				Target = CFrame.new(),
				Elapsed = 0,
				Duration = 1,
				ArcHeight = 1,
				ArcPeakProgress = 0.5,
				Obstacle = climbable,
			},
		})).to.equal(false)
		expect(ParkourState.kind(controller)).to.equal("Mantling")
		expect(ParkourState.enter(controller, { kind = "Grounded" })).to.equal(true)
		expect(ParkourState.enter(controller, { kind = "Unknown" } :: any)).to.equal(false)
		expect(ParkourState.kind(controller)).to.equal("Grounded")
	end)

	it("keeps state data only while its state is active", function()
		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect((ParkourState.hang(controller) :: any).CurrentClimbable).to.equal(climbable)
		expect(ParkourState.mantle(controller)).to.equal(nil)

		expect(ParkourState.enter(controller, mantling(0))).to.equal(true)
		expect(ParkourState.hang(controller)).to.equal(nil)
		expect((ParkourState.mantle(controller) :: any).Duration).to.equal(0.35)

		expect(ParkourState.enter(controller, { kind = "Grounded" })).to.equal(true)
		expect(ParkourState.mantle(controller)).to.equal(nil)
	end)

	it("blocks attacks, sprint and vaults while hanging and grabs while mantling", function()
		local state = fixture.State
		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect(state:CanStart("Attack")).to.equal(false)
		expect(state:CanStart("Charge")).to.equal(false)
		expect(state:CanStart("Sprint")).to.equal(false)
		expect(state:CanStart("Vault")).to.equal(false)
		expect(state:CanStart("Grab")).to.equal(true)

		expect(ParkourState.enter(controller, mantling(0))).to.equal(true)
		expect(state:IsActive("Hang")).to.equal(false)
		expect(state:IsActive("Mantle")).to.equal(true)
		expect(state:CanStart("Grab")).to.equal(false)
		expect(state:CanStart("Attack")).to.equal(false)
	end)

	it("hands the hang lease to the mantle without briefly unblocking sprint", function()
		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		local sprint_allowed_during_handoff = false
		fixture.State.Changed:Connect(function()
			if fixture.State:CanStart("Sprint") then
				sprint_allowed_during_handoff = true
			end
		end)
		expect(ParkourState.enter(controller, mantling(0))).to.equal(true)
		expect(sprint_allowed_during_handoff).to.equal(false)
	end)

	it("restores the hanging pose and releases its sprint blocker exactly once", function()
		local humanoid = fixture.Humanoid
		local changes = fixture.Changes

		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(false)
		expect(humanoid.PlatformStand).to.equal(true)
		controller.CornerProbeMiss = {
			Climbable = climbable,
			Direction = 1,
			Normal = Vector3.xAxis,
			HangPosition = Vector3.new(1, 2, 3),
			RootPosition = Vector3.new(1, 2, 3),
			At = 0,
		}
		local before = #changes

		controller:_release()
		controller:_release()

		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(ParkourState.hang(controller)).to.equal(nil)
		expect(controller.CornerProbeMiss).to.equal(nil)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(fixture.State:IsActive("Hang")).to.equal(false)
		expect(#changes - before).to.equal(1)
		expect(changes[before + 1].Activity).to.equal("Hang")
		expect(changes[before + 1].Active).to.equal(false)
	end)

	it("updates a vault from stored traversal state and finishes on completion", function()
		local humanoid = fixture.Humanoid
		local root = fixture.Root
		local overrides = fixture.State:Overrides(humanoid)
		local jumping = Enum.HumanoidStateType.Jumping

		expect(ParkourState.enter(controller, {
			kind = "Vaulting",
			data = {
				Start = CFrame.new(0, 0, 0),
				Target = CFrame.new(0, 2, -4),
				Elapsed = 0,
				Duration = 1,
				ArcHeight = 1,
				ArcPeakProgress = 0.5,
				ExitVelocity = Vector3.new(8, 0, 0),
				Obstacle = climbable,
			},
		})).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(false)
		expect(humanoid.PlatformStand).to.equal(true)

		expect(VaultTraversal.update_vault(controller, 0.25)).to.equal(true)
		local vault = ParkourState.vault(controller)
		expect(vault.Elapsed).to.equal(0.25)
		expect(math.abs(root.CFrame.Position.Z - (-1)) < 1e-4).to.equal(true)
		expect(overrides:Base("JumpingEnabled")).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		expect(VaultTraversal.update_vault(controller, 1)).to.equal(true)
		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(ParkourState.vault(controller)).to.equal(nil)
		expect(fixture.State:IsActive("Vault")).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)

		expect(function()
			VaultTraversal.update_vault(controller, 0.1)
		end).never.to.throw()
	end)

	it("restores the original HipHeight after the vault crouch", function()
		local humanoid = fixture.Humanoid
		humanoid.HipHeight = 2
		local original = humanoid.HipHeight
		expect(ParkourState.enter(controller, {
			kind = "Vaulting",
			data = {
				Start = CFrame.new(0, 0, 0),
				Target = CFrame.new(0, 0, -4),
				Elapsed = 0,
				Duration = 1,
				ArcHeight = 1,
				ArcPeakProgress = 0.5,
				ExitVelocity = Vector3.zero,
				Obstacle = climbable,
			},
		})).to.equal(true)

		VaultTraversal.update_vault(controller, 0.5)
		expect(humanoid.HipHeight < original).to.equal(true)
		VaultTraversal.update_vault(controller, 1)
		expect(humanoid.HipHeight).to.equal(original)
	end)

	it("restores Jumping and movement properties when a mantle is interrupted", function()
		local humanoid = fixture.Humanoid
		local changes = fixture.Changes
		local jumping = Enum.HumanoidStateType.Jumping

		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect(ParkourState.enter(controller, mantling(0.2))).to.equal(true)
		expect(controller.Latch:IsBlocked("Jump")).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)
		expect(humanoid.AutoRotate).to.equal(false)
		expect(humanoid.PlatformStand).to.equal(true)
		local before = #changes

		controller:_release()

		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(ParkourState.mantle(controller)).to.equal(nil)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(controller.Latch:IsBlocked("Jump")).to.equal(false)
		expect(fixture.State:IsActive("Mantle")).to.equal(false)
		expect(fixture.State:IsActive("Hang")).to.equal(false)
		expect(#changes - before).to.equal(1)
		expect(changes[before + 1].Activity).to.equal("Mantle")
		expect(changes[before + 1].Active).to.equal(false)
	end)

	it("keeps Jumping disabled after a completed mantle until Jump is released", function()
		local humanoid = fixture.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping
		fixture.Input.Down[Actions.Jump] = true

		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)
		expect(ParkourState.enter(controller, mantling(0.3))).to.equal(true)
		controller:_step(0.1)

		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		fixture.Input.Down[Actions.Jump] = nil
		controller:_step(0.1)
		expect(controller.Latch:IsBlocked("Jump")).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
	end)

	it("keeps the vault Jumping override until vault cleanup after Jump is released", function()
		local humanoid = fixture.Humanoid
		local overrides = fixture.State:Overrides(humanoid)
		local jumping = Enum.HumanoidStateType.Jumping

		controller.Latch:Block("Jump")
		expect(ParkourState.enter(controller, {
			kind = "Vaulting",
			data = {
				Start = fixture.Root.CFrame,
				Target = fixture.Root.CFrame * CFrame.new(0, 0, -5),
				Elapsed = 0,
				Duration = 1,
				ArcHeight = 1,
				ArcPeakProgress = 0.5,
				ExitVelocity = Vector3.zero,
				Obstacle = climbable,
			},
		})).to.equal(true)
		fixture.Input.Down[Actions.Jump] = nil

		controller:_step(0.1)

		expect(controller.Latch:IsBlocked("Jump")).to.equal(false)
		expect(overrides:Base("JumpingEnabled")).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		controller:_release()

		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(fixture.State:IsActive("Vault")).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
	end)

	it("hands the vault Jumping override to the Jump latch when a vault completes with Jump held", function()
		local humanoid = fixture.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping
		fixture.Input.Down[Actions.Jump] = true

		expect(ParkourState.enter(controller, {
			kind = "Vaulting",
			data = {
				Start = CFrame.new(),
				Target = CFrame.new(0, 0, -2),
				Elapsed = 0,
				Duration = 0.5,
				ArcHeight = 1,
				ArcPeakProgress = 0.5,
				ExitVelocity = Vector3.zero,
				Obstacle = climbable,
			},
		})).to.equal(true)
		VaultTraversal.update_vault(controller, 1)

		expect(ParkourState.kind(controller)).to.equal("Grounded")
		expect(controller.Latch:IsBlocked("Jump")).to.equal(true)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		fixture.Input.Down[Actions.Jump] = nil
		controller:_step(1 / 60)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
	end)

	it("restores a pending grounded jump lock and makes Destroy idempotent", function()
		local humanoid = fixture.Humanoid
		local jumping = Enum.HumanoidStateType.Jumping
		local overrides = fixture.State:Overrides(humanoid)

		controller.Latch:Block("Jump", { overrides:Push("Mantle", { JumpingEnabled = false }) })
		expect(humanoid:GetStateEnabled(jumping)).to.equal(false)

		controller:Destroy()
		local changes_after_destroy = #fixture.Changes
		controller:Destroy()

		expect(controller._destroyed).to.equal(true)
		expect(controller.Latch:IsBlocked("Jump")).to.equal(false)
		expect(humanoid:GetStateEnabled(jumping)).to.equal(true)
		expect(#fixture.Changes).to.equal(changes_after_destroy)
		controller = nil
	end)

	it("releases every parkour lease and override on Destroy", function()
		local humanoid = fixture.Humanoid
		expect(ParkourState.enter(controller, hanging(climbable))).to.equal(true)

		controller:Destroy()
		controller = nil

		expect(fixture.State:IsActive("Hang")).to.equal(false)
		expect(humanoid.AutoRotate).to.equal(true)
		expect(humanoid.PlatformStand).to.equal(false)
	end)
	end)
end
