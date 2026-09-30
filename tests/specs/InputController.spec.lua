local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Signal = require(ReplicatedStorage.packages.Signal)
local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local InputController = require(Client.controllers.InputController)
local PCInput = require(Client.input.PC)
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

	it("keeps Sprint active when a Shift end is misidentified, then ends when all keys are up", function()
		local began_count = 0
		local ended_count = 0
		local held_keys = {}
		controller.ActionBegan:Connect(function(action)
			if action == Actions.Sprint then began_count += 1 end
		end)
		controller.ActionEnded:Connect(function(action)
			if action == Actions.Sprint then ended_count += 1 end
		end)

		local function on_began(action, source, source_id)
			controller:_began(action, source, source_id)
		end
		local function on_ended(action, source, source_id)
			controller:_ended(action, source, source_id)
		end
		local function reconcile(pressed_keys)
			local active, began, ended = PCInput._reconcile_sprint_state(
				held_keys,
				controller:IsDown(Actions.Sprint),
				pressed_keys,
				on_began,
				on_ended
			)
			return active, began, ended
		end

		-- Match the supplied Studio trace: LeftShift is the held key, while
		-- Roblox reports an InputEnded event whose KeyCode is RightShift.
		local active, began, ended = reconcile({
			[Enum.KeyCode.LeftShift] = true,
		})
		expect(active).to.equal(true)
		expect(began).to.equal(true)
		expect(ended).to.equal(false)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		-- The mismatched event itself must not end Sprint while LeftShift
		-- remains in GetKeysPressed.
		active, began, ended = reconcile({
			[Enum.KeyCode.LeftShift] = true,
		})
		expect(active).to.equal(true)
		expect(began).to.equal(false)
		expect(ended).to.equal(false)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)
		expect(ended_count).to.equal(0)

		-- Once the final physical Shift key is released, reconciliation ends it.
		active, began, ended = reconcile({})
		expect(active).to.equal(false)
		expect(began).to.equal(false)
		expect(ended).to.equal(true)
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		expect(began_count).to.equal(1)
		expect(ended_count).to.equal(1)

		-- Also recover when RightShift's begin event is suppressed: the pressed
		-- key snapshot remains authoritative until that physical key is released.
		active, began, ended = reconcile({
			[Enum.KeyCode.LeftShift] = true,
			[Enum.KeyCode.RightShift] = true,
		})
		expect(active).to.equal(true)
		expect(began).to.equal(true)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)
		active, began, ended = reconcile({
			[Enum.KeyCode.RightShift] = true,
		})
		expect(active).to.equal(true)
		expect(ended).to.equal(false)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)
		active, began, ended = reconcile({})
		expect(active).to.equal(false)
		expect(ended).to.equal(true)
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		expect(began_count).to.equal(2)
		expect(ended_count).to.equal(2)
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
end
