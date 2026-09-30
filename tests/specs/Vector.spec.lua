local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Vector = require(ReplicatedStorage.shared.utility.Vector)

return function()
	describe("Vector.flatten", function()
		it("removes the vertical component", function()
			local result = Vector.flatten(Vector3.new(4, 7, -2))

			expect(result).to.equal(Vector3.new(4, 0, -2))
		end)

		it("preserves horizontal components for a vertical-only vector", function()
			local result = Vector.flatten(Vector3.new(0, 5, 0))

			expect(result).to.equal(Vector3.zero)
		end)
	end)
end
