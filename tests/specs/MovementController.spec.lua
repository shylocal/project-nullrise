local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local MovementConfig = require(ReplicatedStorage.shared.config).Movement
local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local MovementController = require(Controllers.MovementController)
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)

local function make_input()
	local input = {
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
	}
	function input:IsDown(action)
		return self.Down[action] == true
	end
	function input:Press(action)
		self.Down[action] = true
		self.ActionBegan:Fire(action)
	end
	function input:Release(action)
		self.Down[action] = nil
		self.ActionEnded:Fire(action)
	end
	function input:Destroy()
		self.ActionBegan:Destroy()
		self.ActionEnded:Destroy()
	end
	return input
end

return function()
	describe("MovementController", function()
	local character
	local humanoid
	local input
	local state
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
		state = CharacterState.new({ policy = Policy })
		movement = MovementController.new({ character = character, input = input, state = state })
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
		if state then
			state:Destroy()
			state = nil
		end
		if input then
			input:Destroy()
			input = nil
		end
		if character then
			character:Destroy()
			character = nil
		end
		humanoid = nil
	end)

	it("requires every constructor dependency", function()
		expect(function()
			MovementController.new({ character = character, input = input })
		end).to.throw()
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
		local other_state = CharacterState.new({ policy = Policy })
		local other_movement = MovementController.new({
			character = other_character,
			input = other_input,
			state = other_state,
		})

		expect(other_movement.DefaultWalkSpeed).to.equal(MovementConfig.WalkSpeed)
		expect(other_humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)

		other_movement:Destroy()
		other_state:Destroy()
		other_input:Destroy()
		other_character:Destroy()
	end)

	it("defines a valid sprint movement threshold", function()
		local threshold = MovementConfig.SprintMinMoveMagnitude
		expect(typeof(threshold)).to.equal("number")
		expect(threshold > 0 and threshold <= 1).to.equal(true)
	end)

	it("does not sprint while Sprint is held without movement", function()
		set_moving(false)
		input:Press(Actions.Sprint)
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
		input:Press(Actions.Sprint)
		expect(movement:IsSprinting()).to.equal(true)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.SprintSpeed)

		input:Release(Actions.Sprint)
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)
	end)

	it("keeps sprint blocked until every independent blocker is cleared", function()
		local parkour_owner = {}
		local combat_owner = {}

		input:Press(Actions.Sprint)
		local parkour_lease = state:Acquire(parkour_owner, "Hang")
		local combat_lease = state:Acquire(combat_owner, "AttackRooted")
		expect(movement:IsSprinting()).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.WalkSpeed)

		parkour_lease:Release()
		expect(movement:IsSprinting()).to.equal(false)

		combat_lease:Release()
		expect(movement:IsSprinting()).to.equal(true)
		expect(humanoid.WalkSpeed).to.equal(MovementConfig.SprintSpeed)
	end)

	it("does not block sprint for activities whose policy allows it", function()
		input:Press(Actions.Sprint)
		local lease = state:Acquire({}, "TopHop")
		expect(movement:IsSprinting()).to.equal(true)
		lease:Release()
	end)

	it("applies valid speed overrides and rejects invalid values without changing them", function()
		expect(movement:SetSpeeds(12, 28)).to.equal(true)
		input:Press(Actions.Sprint)
		expect(humanoid.WalkSpeed).to.equal(28)

		expect(movement:SetSpeeds(-1, 40)).to.equal(false)
		expect(movement:SetSpeeds(10, math.huge)).to.equal(false)
		expect(humanoid.WalkSpeed).to.equal(28)

		input:Release(Actions.Sprint)
		expect(humanoid.WalkSpeed).to.equal(12)
	end)

	it("emits sprint changes only when the effective sprint state changes", function()
		local changes = {}
		movement.SprintingChanged:Connect(function(sprinting)
			table.insert(changes, sprinting)
		end)

		input:Press(Actions.Sprint)
		local lease = state:Acquire("test", "Hang")
		lease:Release()
		lease:Release()
		input:Release(Actions.Sprint)

		expect(#changes).to.equal(4)
		expect(changes[1]).to.equal(true)
		expect(changes[2]).to.equal(false)
		expect(changes[3]).to.equal(true)
		expect(changes[4]).to.equal(false)
	end)
	end)
end
