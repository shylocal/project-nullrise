local ServerScriptService = game:GetService("ServerScriptService")

local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local MovementValidation = require(Services.MovementValidation)

return function()
	describe("Movement boundary validation", function()
		it("allows ordinary walk and sprint displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(2.4, 0, 0),
				0.1
			)).to.equal(nil)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(12, 0, 0),
				0.5
			)).to.equal(nil)
		end)

		it("allows scripted parkour-scale horizontal displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(13.5, 0, 0),
				0.2
			)).to.equal(nil)
		end)

		it("ignores large movement while a character is settling", function()
			local Workspace = game:GetService("Workspace")
			local character = Instance.new("Model")
			character.Parent = Workspace

			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Position = Vector3.zero
			root.Parent = character

			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character

			local player = {}
			local now = os.clock()
			local state = {
				Character = character,
				Position = Vector3.zero,
				LastSampleAt = now - 0.1,
				IgnoreUntil = now + 1,
				ViolationCount = 0,
				LastReason = nil,
				LastViolationAt = 0,
			}

			local service = setmetatable({}, MovementValidation)
			root.Position = Vector3.new(0, 100, 0)
			service:_observe(player, state, now)

			expect(state.ViolationCount).to.equal(0)
			expect(state.LastReason).to.equal(nil)
			expect(state.Position).to.equal(root.Position)

			character:Destroy()
		end)

		it("flags implausible horizontal displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(10, 0, 0),
				0.05
			)).to.equal("HorizontalSpeed")
		end)

		it("flags implausible vertical displacement", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(0, 8, 0),
				0.05
			)).to.equal("VerticalSpeed")
		end)

		it("flags large teleports before speed classification", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(41, 0, 0),
				0.5
			)).to.equal("TeleportDistance")
		end)

		it("ignores samples with invalid or excessive time gaps", function()
			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(1000, 0, 0),
				0
			)).to.equal(nil)

			expect(MovementValidation.ClassifyDelta(
				Vector3.zero,
				Vector3.new(1000, 0, 0),
				0.51
			)).to.equal(nil)
		end)
	end)
end
