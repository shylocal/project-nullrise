local StarterPlayer = game:GetService("StarterPlayer")

local LedgeDetection = require(
	StarterPlayer:WaitForChild("StarterPlayerScripts")
		:WaitForChild("client")
		:WaitForChild("controllers")
		:WaitForChild("ParkourController")
		:WaitForChild("LedgeDetection")
)

return function()
	describe("Parkour ledge detection", function()
		it("selects the nearest reachable lower surface", function()
			local current_top = Vector3.new(0, 10, 0)
			local normal = Vector3.zAxis
			local tangent = Vector3.xAxis

			local selected = LedgeDetection.select_lower_top(current_top, normal, tangent, {
				{
					Position = Vector3.new(2, 8, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(0.5, 9, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(0, 6, -1),
					Normal = Vector3.yAxis,
				},
			})

			expect(selected.Position).to.equal(Vector3.new(0.5, 9, -1))
		end)

		it("selects the nearest reachable higher surface", function()
			local current_top = Vector3.new(0, 10, 0)
			local normal = Vector3.zAxis
			local tangent = Vector3.xAxis

			local selected = LedgeDetection.select_higher_top(current_top, normal, tangent, 7, {
				{
					Position = Vector3.new(2, 13, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(0.5, 11, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(0, 14, -1),
					Normal = Vector3.yAxis,
				},
			})

			expect(selected.Position).to.equal(Vector3.new(0.5, 11, -1))
		end)

		it("uses horizontal distance to break equal-height ties", function()
			local current_top = Vector3.new(0, 10, 0)
			local normal = Vector3.zAxis
			local tangent = Vector3.xAxis

			local selected = LedgeDetection.select_higher_top(current_top, normal, tangent, 8, {
				{
					Position = Vector3.new(2, 11, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(0.5, 11, -1),
					Normal = Vector3.yAxis,
				},
			})

			expect(selected.Position).to.equal(Vector3.new(0.5, 11, -1))
		end)

		it("rejects surfaces outside vertical or horizontal reach", function()
			local current_top = Vector3.new(0, 10, 0)
			local normal = Vector3.zAxis
			local tangent = Vector3.xAxis

			local selected = LedgeDetection.select_higher_top(current_top, normal, tangent, 8, {
				{
					Position = Vector3.new(0, 13.5, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(6, 11, -1),
					Normal = Vector3.yAxis,
				},
			})

			expect(selected).to.equal(nil)
		end)
	end)
end
