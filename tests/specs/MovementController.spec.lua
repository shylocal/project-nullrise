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
	}, InputController)
end

local function destroy_input(input)
	input.ActionBegan:Destroy()
	input.ActionEnded:Destroy()
	table.clear(input.Down)
end

return function()
	describe("MovementController", function()
	local character
	local humanoid
	local input
	local movement

	beforeEach(function()
		character = Instance.new("Model")
		character.Name = "MovementControllerSpecCharacter"

		humanoid = Instance.new("Humanoid")
		humanoid.Parent = character

		input = make_input()
		movement = MovementController.new(character, input)
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

	it("starts at the Humanoid's default walk speed", function()
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)
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

		expect(#changes).to.equal(3)
		expect(changes[1]).to.equal(true)
		expect(changes[2]).to.equal(false)
		expect(changes[3]).to.equal(true)
	end)
	end)
end
