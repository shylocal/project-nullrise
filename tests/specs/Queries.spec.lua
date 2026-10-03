local CollectionService = game:GetService("CollectionService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Client = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local Queries = require(Client.controllers.ParkourController.Queries)
local Config = require(Client.controllers.ParkourController.Config)

local function make_fixture()
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
		_queryMetricsEnabled = true,
		_queryMetrics = {},
	}
	function controller:_standing_height()
		return 3
	end

	return controller, character
end

local function destroy_fixture(controller, instances)
	for _, instance in ipairs(instances) do
		CollectionService:RemoveTag(instance, Config.ClimbableTag)
		instance:Destroy()
	end
	controller.Character:Destroy()
end

return function()
	describe("Parkour spatial query contracts", function()
		it("uses the explicit optional wall context without nil globals", function()
			local controller, character = make_fixture()
			local ledge = Instance.new("Part")
			ledge.Name = "TaggedLedge"
			ledge.Size = Vector3.new(5, 1, 2)
			ledge.CFrame = CFrame.new(0, 4, 0)
			ledge.Parent = Workspace
			CollectionService:AddTag(ledge, Config.ClimbableTag)

			local top = Queries.cast_reachable_grab_top(
				controller,
				Vector3.new(0, 4, 0),
				Vector3.new(0, 0, 1),
				controller.Root.Position,
				controller.Root.Position.Y,
				Config.MaxGrabHeight,
				ledge
			)

			expect(top ~= nil).to.equal(true)
			expect(top.Instance).to.equal(ledge)
			expect(top.Position.Y).to.equal(4.5)

			destroy_fixture(controller, { ledge })
		end)

		it("counts each decorative side-raycast once", function()
			local controller, character = make_fixture()
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
			expect(controller._queryMetrics.Raycasts).to.equal(2)

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

			probe:Destroy()
			destroy_fixture(controller, { blocker })
		end)
	end)
end
