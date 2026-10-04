--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
-- Direct indexing: a missing client tree should fail loudly, not yield forever.
local Client = StarterPlayer.StarterPlayerScripts.client
local InputController = require(Client.controllers.InputController)
local PCInput = require(Client.input.PC)
local ClientTrove = require(Client.ClientTrove)
local GamepadInput = require(Client.input.Gamepad)
local Actions = require(ReplicatedStorage.shared.input.Actions)

-- Builds a controller over one fake adapter; `hooks.began` / `hooks.ended`
-- are the reporters the controller hands its adapters.
type Hooks = {
	Destroyed: boolean,
	began: InputController.Report,
	ended: InputController.Report,
}

local function make_controller(initial_source: string?)
	local hooks: Hooks = {
		Destroyed = false,
		began = function() end,
		ended = function() end,
	}
	local focus_released = Signal.new()
	local controller = InputController.from_adapters({
		adapters = {
			function(began, ended)
				hooks.began = began
				hooks.ended = ended
				return {
					Destroy = function()
						hooks.Destroyed = true
					end,
				}
			end,
		},
		focus_released = focus_released,
		initial_source = initial_source,
	})
	return controller, hooks, focus_released
end

-- Adapters are thin binding tables; specs build them without ContextActionService.
local function make_gamepad(ui_navigating: boolean)
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
		-- A partial adapter (no bindings, overridden UI check), so not a
		-- GamepadInput as far as the analyzer knows.
	}, GamepadInput) :: any
	return gamepad, calls
end

local function gamepad_input(key_code: Enum.KeyCode)
	return { UserInputType = Enum.UserInputType.Gamepad1, KeyCode = key_code }
end

return function()
	describe("InputController action state", function()
		local controller: InputController.InputController
		local hooks: Hooks
		local focus_released: typeof(Signal.new())

		beforeEach(function()
			controller, hooks, focus_released = make_controller(nil)
		end)

		afterEach(function()
			-- Destroy is idempotent, so a spec that already destroyed it is fine.
			controller:Destroy()
		end)

		it("tracks an action from begin through end", function()
			expect(controller:IsDown(Actions.Jump)).to.equal(false)

			hooks.began(Actions.Jump)
			expect(controller:IsDown(Actions.Jump)).to.equal(true)

			hooks.ended(Actions.Jump)
			expect(controller:IsDown(Actions.Jump)).to.equal(false)
		end)

		it("emits each begin and end transition only once", function()
			local began_count = 0
			local ended_count = 0
			controller.ActionBegan:Connect(function(action)
				if action == Actions.Forward then
					began_count += 1
				end
			end)
			controller.ActionEnded:Connect(function(action)
				if action == Actions.Forward then
					ended_count += 1
				end
			end)

			hooks.began(Actions.Forward)
			hooks.began(Actions.Forward)
			hooks.ended(Actions.Forward)
			hooks.ended(Actions.Forward)

			expect(began_count).to.equal(1)
			expect(ended_count).to.equal(1)
		end)

		it("releases all held actions when focus is lost", function()
			local ended = {}
			controller.ActionEnded:Connect(function(action)
				ended[action] = (ended[action] or 0) + 1
			end)

			hooks.began(Actions.Jump)
			hooks.began(Actions.Forward)
			hooks.began(Actions.Sprint)
			focus_released:Fire()

			expect(controller:IsDown(Actions.Jump)).to.equal(false)
			expect(controller:IsDown(Actions.Forward)).to.equal(false)
			expect(controller:IsDown(Actions.Sprint)).to.equal(false)
			expect(ended[Actions.Jump]).to.equal(1)
			expect(ended[Actions.Forward]).to.equal(1)
			expect(ended[Actions.Sprint]).to.equal(1)
		end)

		it("does not emit duplicate end events after a focus release", function()
			local ended_count = 0
			controller.ActionEnded:Connect(function()
				ended_count += 1
			end)

			hooks.began(Actions.Jump)
			focus_released:Fire()
			hooks.ended(Actions.Jump)

			expect(ended_count).to.equal(1)
		end)

		it("keeps an action down until every physical source releases it", function()
			local began_count = 0
			local ended_count = 0
			controller.ActionBegan:Connect(function(action)
				if action == Actions.Sprint then
					began_count += 1
				end
			end)
			controller.ActionEnded:Connect(function(action)
				if action == Actions.Sprint then
					ended_count += 1
				end
			end)

			hooks.began(Actions.Sprint, "PC", "SprintToggle")
			hooks.began(Actions.Sprint, "PC", Enum.KeyCode.LeftShift)
			expect(began_count).to.equal(1)
			expect(controller:IsDown(Actions.Sprint)).to.equal(true)

			hooks.ended(Actions.Sprint, "PC", "SprintToggle")
			expect(ended_count).to.equal(0)
			expect(controller:IsDown(Actions.Sprint)).to.equal(true)

			hooks.ended(Actions.Sprint, "PC", Enum.KeyCode.LeftShift)
			expect(ended_count).to.equal(1)
			expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		end)

		it("emits final releases and destroys its adapters on Destroy", function()
			local ended = {}
			controller.ActionEnded:Connect(function(action)
				table.insert(ended, action)
			end)
			hooks.began(Actions.Jump)

			controller:Destroy()
			controller:Destroy()

			expect(#ended).to.equal(1)
			expect(hooks.Destroyed).to.equal(true)

			-- Reports after Destroy are ignored.
			hooks.began(Actions.Forward)
			expect(controller:IsDown(Actions.Forward)).to.equal(false)
		end)
	end)

	describe("InputController device switching", function()
		it("preserves held actions when switching within the same device family", function()
			local controller, hooks = make_controller("PC")
			local ended_count = 0
			controller.ActionEnded:Connect(function()
				ended_count += 1
			end)

			hooks.began(Actions.Jump, "PC", Enum.KeyCode.Space)
			hooks.began(Actions.Forward, "PC", Enum.KeyCode.W)

			expect(controller:IsDown(Actions.Jump)).to.equal(true)
			expect(ended_count).to.equal(0)
			expect(controller:GetActiveSource()).to.equal("PC")
			controller:Destroy()
		end)

		it("releases held actions from the previous device when input changes", function()
			local controller, hooks = make_controller("PC")
			local ended = {}
			controller.ActionEnded:Connect(function(action)
				table.insert(ended, action)
			end)

			hooks.began(Actions.Jump, "PC")
			hooks.began(Actions.Forward, "PC")
			expect(controller:IsDown(Actions.Jump)).to.equal(true)

			hooks.began(Actions.Primary, "Mobile")

			expect(controller:GetActiveSource()).to.equal("Mobile")
			expect(controller:IsDown(Actions.Jump)).to.equal(false)
			expect(controller:IsDown(Actions.Forward)).to.equal(false)
			expect(controller:IsDown(Actions.Primary)).to.equal(true)
			expect(#ended).to.equal(2)

			-- A late release from the old device is ignored.
			hooks.ended(Actions.Jump, "PC")
			expect(#ended).to.equal(2)
			controller:Destroy()
		end)
	end)

	describe("PC adapter", function()
		it("binds number keys to every generated slot action", function()
			local keys = {
				Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
				Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six,
				Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
			}
			for index, slot_action in ipairs(Actions.Slots) do
				expect(PCInput.Bindings[keys[index]]).to.equal(slot_action)
				expect(Actions.slot_index(slot_action)).to.equal(index)
			end
		end)

		it("tracks Left Shift as a held sprint input", function()
			local controller, hooks = make_controller(nil)
			local began_count = 0
			local ended_count = 0
			local pc_input = setmetatable({
				SprintActive = false,
				OnBegan = function(...)
					began_count += 1
					hooks.began(...)
				end,
				OnEnded = function(...)
					ended_count += 1
					hooks.ended(...)
				end,
				-- A partial adapter that binds nothing, so not a PCInput as
				-- far as the analyzer knows.
			}, PCInput) :: any

			pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.LeftShift })
			expect(controller:IsDown(Actions.Sprint)).to.equal(true)
			expect(began_count).to.equal(1)

			pc_input:_on_sprint_input("Sprint", Enum.UserInputState.End, { KeyCode = Enum.KeyCode.LeftShift })
			expect(controller:IsDown(Actions.Sprint)).to.equal(false)
			expect(ended_count).to.equal(1)
			controller:Destroy()
		end)

		it("begins sprint on the first Left Shift press after a focus loss", function()
			local pc_input: any = nil
			local focus_released = Signal.new()
			local controller = InputController.from_adapters({
				adapters = {
					function(began, ended)
						pc_input = setmetatable({
							Trove = ClientTrove.new(),
							SprintActive = false,
							OnBegan = began,
							OnEnded = ended,
							_destroyed = false,
							-- A partial adapter that binds nothing, so not a
							-- PCInput as far as the analyzer knows.
						}, PCInput) :: any
						return pc_input
					end,
				},
				focus_released = focus_released,
			})
			local began_count = 0
			controller.ActionBegan:Connect(function(action)
				if action == Actions.Sprint then
					began_count += 1
				end
			end)
			local shift = { KeyCode = Enum.KeyCode.LeftShift }

			pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, shift)
			expect(began_count).to.equal(1)

			-- Focus is lost while Shift is held; its End never arrives.
			focus_released:Fire()
			expect(controller:IsDown(Actions.Sprint)).to.equal(false)
			expect(pc_input.SprintActive).to.equal(false)

			pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, shift)
			expect(controller:IsDown(Actions.Sprint)).to.equal(true)
			expect(began_count).to.equal(2)
			controller:Destroy()
		end)

		it("still accepts adapters without ReleaseAll on focus loss", function()
			local controller, hooks, focus_released = make_controller(nil)
			hooks.began(Actions.Jump)
			focus_released:Fire()
			expect(controller:IsDown(Actions.Jump)).to.equal(false)
			controller:Destroy()
		end)

		it("ignores Right Shift as a sprint input", function()
			local began_count = 0
			local pc_input = setmetatable({
				SprintActive = false,
				OnBegan = function() began_count += 1 end,
				OnEnded = function() end,
				-- A partial adapter that binds nothing.
			}, PCInput) :: any

			pc_input:_on_sprint_input("Sprint", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.RightShift })
			expect(began_count).to.equal(0)
			expect(pc_input.SprintActive).to.equal(false)
		end)
	end)

	describe("Gamepad adapter", function()
		local function press(gamepad: any, action: string, input_state: Enum.UserInputState)
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
			local controller, hooks = make_controller(nil)
			local gamepad = setmetatable({
				Actions = {},
				OnBegan = hooks.began,
				OnEnded = hooks.ended,
				_is_ui_navigating = function()
					return false
				end,
				-- A partial adapter that binds nothing.
			}, GamepadInput) :: any

			press(gamepad, Actions.Jump, Enum.UserInputState.Begin)
			expect(controller:IsDown(Actions.Jump)).to.equal(true)
			press(gamepad, Actions.Jump, Enum.UserInputState.End)
			expect(controller:IsDown(Actions.Jump)).to.equal(false)

			controller:Destroy()
		end)
	end)
end
