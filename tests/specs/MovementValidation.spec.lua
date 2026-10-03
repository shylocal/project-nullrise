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
				Vector3.new(8, 8, 0),
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
