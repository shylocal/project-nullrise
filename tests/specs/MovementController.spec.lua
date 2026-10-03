local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local MovementConfig = require(ReplicatedStorage.shared.movement.Config)
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local InputController = require(Client.controllers.InputController)
local MovementController = require(Client.controllers.MovementController)

local function make_input()
	return setmetatable({
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
		SourcesDown = {},
		ActiveInputSource = nil,
	}, InputController)
end

local function destroy_input(input)
	input.ActionBegan:Destroy()
	input.ActionEnded:Destroy()
	table.clear(input.Down)
	table.clear(input.SourcesDown)
end

return function()
	describe("MovementController", function()
	local character
	local humanoid
	local input
	local movement
	local moving

	-- Humanoid.MoveDirection is read-only from scripts, so specs drive the
	-- movement gate through the controller's _is_moving hook instead.
	local function set_moving(value)
		moving = value
		movement:_update_sprinting()
	end

	beforeEach(function()
		character = Instance.new("Model")
		character.Name = "MovementControllerSpecCharacter"

		humanoid = Instance.new("Humanoid")
		humanoid.Parent = character

		input = make_input()
		movement = MovementController.new(character, input)
		moving = true
		movement._is_moving = function()
			return moving
		end
	end)

	afterEach(function()
		if movement then
			movement:Destroy()
			movement = nil
		end
		if input then
			destroy_input(input)
			input = nil
		end
		if character then
			character:Destroy()
			character = nil
		end
		humanoid = nil
	end)

	it("starts at the configured walk speed", function()
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)
	end)

	it("applies the configured walk speed instead of adopting the Humanoid's", function()
		local other_character = Instance.new("Model")
		local other_humanoid = Instance.new("Humanoid")
		other_humanoid.WalkSpeed = MovementConfig.WalkSpeed + 7
		other_humanoid.Parent = other_character
		local other_input = make_input()
		local other_movement = MovementController.new(other_character, other_input)

		expect(other_movement.DefaultWalkSpeed).to.equal(MovementConfig.WalkSpeed)
		expect(other_humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)

		other_movement:Destroy()
		destroy_input(other_input)
		other_character:Destroy()
	end)

	it("defines a valid sprint movement threshold", function()
		local threshold = MovementConfig.SprintMinMoveMagnitude
		expect(typeof(threshold)).to.equal("number")
		expect(threshold > 0 and threshold <= 1).to.equal(true)
	end)

	it("does not sprint while Sprint is held without movement", function()
		set_moving(false)
		input:_began(Actions.Sprint)
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)

		set_moving(true)
		expect(movement:IsSprinting()).to.equal(true)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.SprintSpeed)

		set_moving(false)
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)
	end)

	it("treats a stationary Humanoid as not moving", function()
		-- A Humanoid outside the simulated world has a zero MoveDirection.
		expect(MovementController._is_moving(movement)).to.equal(false)
	end)

	it("switches between walk and sprint speeds from input transitions", function()
		input:_began(Actions.Sprint)
		expect(movement:IsSprinting()).to.equal(true)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.SprintSpeed)

		input:_ended(Actions.Sprint)
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)
	end)

	it("keeps sprint blocked until every independent blocker is cleared", function()
		local parkour_blocker = {}
		local combat_blocker = {}

		input:_began(Actions.Sprint)
		movement:SetSprintBlocked(true, parkour_blocker)
		movement:SetSprintBlocked(true, combat_blocker)
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)

		movement:SetSprintBlocked(false, parkour_blocker)
		expect(movement:IsSprinting()).to.equal(false)

		movement:SetSprintBlocked(false, combat_blocker)
		expect(movement:IsSprinting()).to.equal(true)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.SprintSpeed)
	end)

	it("applies valid speed overrides and rejects invalid values without changing them", function()
		expect(movement:SetSpeeds(12, 28)).to.equal(true)
		input:_began(Actions.Sprint)
		expect(humanoid.WalkSpeed).to.equal(28)

		expect(movement:SetSpeeds(-1, 40)).to.equal(false)
		expect(movement:SetSpeeds(10, math.huge)).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(28)

		input:_ended(Actions.Sprint)
		expect(humanoid.WalkSpeed).to.equal(12)
	end)

	it("emits sprint changes only when the effective sprint state changes", function()
		local changes = {}
		movement.SprintingChanged:Connect(function(sprinting)
			table.insert(changes, sprinting)
		end)

		input:_began(Actions.Sprint)
		movement:SetSprintBlocked(true, "test")
		movement:SetSprintBlocked(true, "test")
		movement:SetSprintBlocked(false, "test")
		input:_ended(Actions.Sprint)

		expect(#changes).to.equal(4)
		expect(changes[1]).to.equal(true)
		expect(changes[2]).to.equal(false)
		expect(changes[3]).to.equal(true)
		expect(changes[4]).to.equal(false)
	end)
	end)
end
