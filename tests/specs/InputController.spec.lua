local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
-- Direct indexing: a missing client tree should fail loudly, not yield forever.
local Client = StarterPlayer.StarterPlayerScripts.client
local InputController = require(Client.controllers.InputController)
local PCInput = require(Client.input.PC)
local GamepadInput = require(Client.input.Gamepad)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local function make_controller()
	return setmetatable({
		ActionBegan = Signal.new(),
		ActionEnded = Signal.new(),
		Down = {},
		SourcesDown = {},
		ActiveInputSource = nil,
	}, InputController)
end

local function make_gamepad(ui_navigating)
	local calls = { Began = {}, Ended = {} }
	local gamepad = setmetatable({
		Actions = {},
		OnBegan = function(action, source, source_id)
			table.insert(calls.Began, { action, source, source_id })
		end,
		OnEnded = function(action, source, source_id)
			table.insert(calls.Ended, { action, source, source_id })
		end,
		_is_ui_navigating = function()
			return ui_navigating
		end,
	}, GamepadInput)
	return gamepad, calls
end

local function gamepad_input(key_code)
	return { UserInputType = Enum.UserInputType.Gamepad1, KeyCode = key_code }
end

local function destroy_controller(controller)
	controller.ActionBegan:Destroy()
	controller.ActionEnded:Destroy()
	table.clear(controller.Down)
	table.clear(controller.SourcesDown)
end

return function()
	describe("InputController action state", function()
	local controller

	beforeEach(function()
		controller = make_controller()
	end)

	afterEach(function()
		if controller then
			destroy_controller(controller)
			controller = nil
		end
	end)

	it("tracks an action from begin through end", function()
		expect(controller:IsDown(Actions.Jump)).to.equal(false)

		controller:_began(Actions.Jump)
		expect(controller:IsDown(Actions.Jump)).to.equal(true)

		controller:_ended(Actions.Jump)
		expect(controller:IsDown(Actions.Jump)).to.equal(false)
	end)

	it("emits each begin and end transition only once", function()
		local began_count = 0
		local ended_count = 0
		controller.ActionBegan:Connect(function(action)
			if action == Actions.Forward then began_count += 1 end
		end)
		controller.ActionEnded:Connect(function(action)
			if action == Actions.Forward then ended_count += 1 end
		end)

		controller:_began(Actions.Forward)
		controller:_began(Actions.Forward)
		controller:_ended(Actions.Forward)
		controller:_ended(Actions.Forward)

		expect(began_count).to.equal(1)
		expect(ended_count).to.equal(1)
	end)

	it("releases all held actions when focus is lost", function()
		local ended = {}
		controller.ActionEnded:Connect(function(action)
			ended[action] = (ended[action] or 0) + 1
		end)

		controller:_began(Actions.Jump)
		controller:_began(Actions.Forward)
		controller:_began(Actions.Sprint)
		controller:_release_all()

		expect(controller:IsDown(Actions.Jump)).to.equal(false)
		expect(controller:IsDown(Actions.Forward)).to.equal(false)
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		expect(ended[Actions.Jump]).to.equal(1)
		expect(ended[Actions.Forward]).to.equal(1)
		expect(ended[Actions.Sprint]).to.equal(1)
	end)

	it("preserves held actions when switching within the same device family", function()
		local ended_count = 0
		controller.ActionEnded:Connect(function()
			ended_count += 1
		end)

		controller.ActiveInputSource = "PC"
		controller:_began(Actions.Jump, "PC", Enum.KeyCode.Space)
		controller:_set_active_source("PC")

		expect(controller:IsDown(Actions.Jump)).to.equal(true)
		expect(ended_count).to.equal(0)
	end)

	it("releases held actions from the previous device when input changes", function()
		local ended = {}
		controller.ActionEnded:Connect(function(action)
			table.insert(ended, action)
		end)

		controller.ActiveInputSource = "PC"
		controller:_began(Actions.Jump, "PC")
		controller:_began(Actions.Forward, "PC")
		expect(controller:IsDown(Actions.Jump)).to.equal(true)

		controller:_set_active_source("Mobile")

		expect(controller.ActiveInputSource).to.equal("Mobile")
		expect(controller:IsDown(Actions.Jump)).to.equal(false)
		expect(controller:IsDown(Actions.Forward)).to.equal(false)
		expect(#ended).to.equal(2)

		controller:_ended(Actions.Jump, "PC")
		expect(#ended).to.equal(2)
	end)

	it("tracks Left Shift as a held sprint input", function()
		local began_count = 0
		local ended_count = 0
		local pc_input = setmetatable({
			SprintKeyDown = false,
			SprintActive = false,
			OnBegan = function(action, source, source_id)
				began_count += 1
				controller:_began(action, source, source_id)
			end,
			OnEnded = function(action, source, source_id)
				ended_count += 1
				controller:_ended(action, source, source_id)
			end,
		}, PCInput)

		pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.LeftShift })
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)
		expect(began_count).to.equal(1)

		pc_input:_on_sprint_input("Sprint", Enum.UserInputState.End, { KeyCode = Enum.KeyCode.LeftShift })
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		expect(ended_count).to.equal(1)
	end)

	it("ignores Right Shift as a sprint input", function()
		local began_count = 0
		local pc_input = setmetatable({
			SprintKeyDown = false,
			SprintActive = false,
			OnBegan = function() began_count += 1 end,
			OnEnded = function() end,
		}, PCInput)

		pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.RightShift })
		expect(began_count).to.equal(0)
		expect(pc_input.SprintActive).to.equal(false)
	end)

	it("keeps an action down until every source releases it", function()
		local began_count = 0
		local ended_count = 0
		controller.ActionBegan:Connect(function(action)
			if action == Actions.Sprint then began_count += 1 end
		end)
		controller.ActionEnded:Connect(function(action)
			if action == Actions.Sprint then ended_count += 1 end
		end)

		controller:_began(Actions.Sprint, "PC")
		controller:_began(Actions.Sprint, "Mobile")
		expect(began_count).to.equal(1)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		controller:_ended(Actions.Sprint, "PC")
		expect(ended_count).to.equal(0)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		controller:_ended(Actions.Sprint, "Mobile")
		expect(ended_count).to.equal(1)
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
	end)
	it("does not emit duplicate end events after a focus release", function()
		local ended_count = 0
		controller.ActionEnded:Connect(function()
			ended_count += 1
		end)

		controller:_began(Actions.Jump)
		controller:_release_all()
		controller:_ended(Actions.Jump)

		expect(ended_count).to.equal(1)
	end)
	end)

	describe("Gamepad adapter", function()
		local function press(gamepad, action, input_state)
			local binding = GamepadInput.Bindings[action]
			return gamepad:_on_input(action, binding, input_state, gamepad_input(binding.KeyCode))
		end

		it("passes ButtonA through so Roblox's default jump still runs", function()
			local gamepad, calls = make_gamepad(false)

			expect(press(gamepad, Actions.Jump, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Pass)
			expect(#calls.Began).to.equal(1)
			expect(calls.Began[1][1]).to.equal(Actions.Jump)
			expect(calls.Began[1][2]).to.equal("Gamepad")
			expect(calls.Began[1][3]).to.equal(Enum.KeyCode.ButtonA)

			expect(press(gamepad, Actions.Jump, Enum.UserInputState.End)).to.equal(Enum.ContextActionResult.Pass)
			expect(#calls.Ended).to.equal(1)
		end)

		it("passes D-pad input through", function()
			local gamepad, calls = make_gamepad(false)

			for _, action in ipairs({ Actions.Forward, Actions.Backward, Actions.Left, Actions.Right }) do
				expect(press(gamepad, action, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Pass)
			end
			expect(#calls.Began).to.equal(4)
		end)

		it("does not report ButtonA or D-pad presses while UI navigation owns them", function()
			local gamepad, calls = make_gamepad(true)

			expect(press(gamepad, Actions.Jump, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Pass)
			expect(press(gamepad, Actions.Forward, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Pass)
			expect(#calls.Began).to.equal(0)

			-- Releases are still forwarded so a hold that began before navigation ends cleanly.
			press(gamepad, Actions.Jump, Enum.UserInputState.End)
			expect(#calls.Ended).to.equal(1)
		end)

		it("still sinks gameplay-only buttons", function()
			local gamepad, calls = make_gamepad(true)

			expect(press(gamepad, Actions.Primary, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Sink)
			expect(press(gamepad, Actions.Slot1, Enum.UserInputState.Begin)).to.equal(Enum.ContextActionResult.Sink)
			expect(#calls.Began).to.equal(2)
		end)

		it("ignores non-gamepad input routed to a gamepad binding", function()
			local gamepad, calls = make_gamepad(false)
			local binding = GamepadInput.Bindings[Actions.Jump]
			local result = gamepad:_on_input(
				Actions.Jump,
				binding,
				Enum.UserInputState.Begin,
				{ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.Space }
			)

			expect(result).to.equal(Enum.ContextActionResult.Pass)
			expect(#calls.Began).to.equal(0)
		end)

		it("feeds InputController without blocking jump", function()
			local controller = make_controller()
			local gamepad = setmetatable({
				Actions = {},
				OnBegan = function(...)
					controller:_began(...)
				end,
				OnEnded = function(...)
					controller:_ended(...)
				end,
				_is_ui_navigating = function()
					return false
				end,
			}, GamepadInput)

			press(gamepad, Actions.Jump, Enum.UserInputState.Begin)
			expect(controller:IsDown(Actions.Jump)).to.equal(true)
			press(gamepad, Actions.Jump, Enum.UserInputState.End)
			expect(controller:IsDown(Actions.Jump)).to.equal(false)

			destroy_controller(controller)
		end)
	end)
end
