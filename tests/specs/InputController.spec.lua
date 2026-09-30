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

	it("releases stale Sprint ownership when the final Shift end is misidentified", function()
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

		-- Reproduce the observed Studio stream: LeftShift begins, pressing
		-- RightShift generates no begin, releasing LeftShift generates no end,
		-- and the final release arrives as an unmatched RightShift end.
		local handled, began = PCInput._begin_sprint_key(held_keys, Enum.KeyCode.LeftShift, on_began)
		expect(handled).to.equal(true)
		expect(began).to.equal(true)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		handled, began = PCInput._begin_sprint_key(held_keys, Enum.KeyCode.RightShift, on_began)
		expect(handled).to.equal(true)
		expect(began).to.equal(false)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		-- The first physical release is suppressed: no helper call occurs.
		expect(held_keys[Enum.KeyCode.LeftShift]).to.equal(true)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		local ended_handled, matched, remains_active, removed_key =
			PCInput._end_sprint_key(held_keys, Enum.KeyCode.RightShift, on_ended)
		expect(ended_handled).to.equal(true)
		expect(matched).to.equal(false)
		expect(remains_active).to.equal(false)
		expect(removed_key).to.equal(Enum.KeyCode.LeftShift)
		expect(controller:IsDown(Actions.Sprint)).to.equal(false)
		expect(began_count).to.equal(1)
		expect(ended_count).to.equal(1)

		-- Standard two-edge input still preserves Sprint until the second key ends.
		PCInput._begin_sprint_key(held_keys, Enum.KeyCode.LeftShift, on_began)
		PCInput._begin_sprint_key(held_keys, Enum.KeyCode.RightShift, on_began)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)

		PCInput._end_sprint_key(held_keys, Enum.KeyCode.LeftShift, on_ended)
		expect(controller:IsDown(Actions.Sprint)).to.equal(true)
		expect(ended_count).to.equal(1)

		PCInput._end_sprint_key(held_keys, Enum.KeyCode.RightShift, on_ended)
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
