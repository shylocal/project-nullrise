local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.packages.Signal)
local Config = require(ReplicatedStorage.shared.config)
local Parkour = StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController
local ClimbableIndex = require(Parkour.ClimbableIndex)
local Metrics = require(Parkour.Metrics)
local Queries = require(Parkour.Queries)
local QueryContext = require(Parkour.QueryContext)

-- A CollectionService stand-in with a fixed tagged list, so specs do not
-- depend on (possibly deferred) tag signals.
local function make_collection(tagged)
	local added = Signal.new()
	local removed = Signal.new()
	return {
		GetTagged = function()
			return tagged
		end,
		GetInstanceAddedSignal = function()
			return added
		end,
		GetInstanceRemovedSignal = function()
			return removed
		end,
	}
end

local function make_fixture(tagged)
	local character = Instance.new("Model")
	character.Name = "ParkourQueriesSpecCharacter"
	character.Parent = Workspace

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(100000, 4, 100000)
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	local controller = {
		Character = character,
		Root = root,
		Humanoid = humanoid,
		Metrics = Metrics.new(true),
		Climbables = ClimbableIndex.new({
			collection = make_collection(tagged or {}),
			tag = Config.World.Tags.Climbable,
			cell_size = 16,
			root = Workspace,
		}),
	}
	controller.Query = QueryContext.new(controller)
	function controller:_standing_height()
		return 3
	end

	return controller
end

local function destroy_fixture(controller, instances)
	for _, instance in ipairs(instances) do
		instance:Destroy()
	end
	if controller.HangClearanceProbe then
		controller.HangClearanceProbe:Destroy()
	end
	controller.Climbables:Destroy()
	controller.Character:Destroy()
end

return function()
	describe("Parkour spatial query contracts", function()
		it("uses the explicit optional wall context without nil globals", function()
			local ledge = Instance.new("Part")
			ledge.Name = "TaggedLedge"
			ledge.Size = Vector3.new(5, 1, 2)
			ledge.CFrame = CFrame.new(0, 4, 0)
			ledge.Parent = Workspace
			local controller = make_fixture({ ledge })

			local top = Queries.cast_reachable_grab_top(
				controller,
				Vector3.new(0, 4, 0),
				Vector3.new(0, 0, 1),
				controller.Root.Position,
				controller.Root.Position.Y,
				Config.Parkour.MaxGrabHeight,
				ledge
			)

			expect(top ~= nil).to.equal(true)
			expect(top.Instance).to.equal(ledge)
			expect(top.Position.Y).to.equal(4.5)

			destroy_fixture(controller, { ledge })
		end)

		it("counts each decorative side-raycast once", function()
			local controller = make_fixture()
			local blocker = Instance.new("Part")
			blocker.Name = "NonCollidableDecoration"
			blocker.Size = Vector3.new(2, 2, 0.5)
			blocker.CanCollide = false
			blocker.CFrame = CFrame.new(100000, 5, 99999)
			blocker.Parent = Workspace

			local result = Queries.cast_grabbable_side(
				controller,
				controller.Root.Position,
				Vector3.new(0, 0, -3)
			)
			expect(result).to.equal(nil)
			expect(Metrics.snapshot(controller).Raycasts).to.equal(2)
			expect(Metrics.snapshot(controller).RaysThisFrame).to.equal(2)

			destroy_fixture(controller, { blocker })
		end)

		it("keeps the hang clearance probe invisible to other spatial queries", function()
			local controller = make_fixture()
			local hang_position = Vector3.new(100000, 40, 100000)

			local clear = Queries.has_hang_body_clearance(controller, hang_position, Vector3.zAxis)
			expect(clear).to.equal(true)

			local probe = controller.HangClearanceProbe
			expect(probe ~= nil).to.equal(true)
			expect(probe.CanQuery).to.equal(false)
			expect(probe.CanCollide).to.equal(false)
			expect(probe.CanTouch).to.equal(false)

			-- A ray that ignores CanCollide must pass straight through the probe.
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { controller.Character }
			params.RespectCanCollide = false
			local hit = Workspace:Raycast(hang_position + Vector3.new(0, 5, 0), Vector3.new(0, -10, 0), params)
			expect(hit == nil or hit.Instance ~= probe).to.equal(true)

			-- The probe still measures overlaps against solid geometry.
			local blocker = Instance.new("Part")
			blocker.Name = "HangClearanceBlocker"
			blocker.Anchored = true
			blocker.Size = Vector3.new(4, 4, 4)
			blocker.CFrame = CFrame.new(hang_position)
			blocker.Parent = Workspace

			local blocked, blocking_part = Queries.has_hang_body_clearance(controller, hang_position, Vector3.zAxis)
			expect(blocked).to.equal(false)
			expect(blocking_part).to.equal(blocker)

			destroy_fixture(controller, { blocker })
		end)
	end)
end
