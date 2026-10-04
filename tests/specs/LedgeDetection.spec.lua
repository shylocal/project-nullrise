local StarterPlayer = game:GetService("StarterPlayer")

local LedgeDetection = require(StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController.LedgeDetection)

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
					Position = Vector3.new(0, 23, -1),
					Normal = Vector3.yAxis,
				},
				{
					Position = Vector3.new(6, 11, -1),
					Normal = Vector3.yAxis,
				},
			})

			expect(selected).to.equal(nil)
		end)

		it("bounds every point a mantle search can accept inside its index query box", function()
			local current_top = Vector3.new(3, 10, -2)
			local normal = Vector3.new(1, 0, 1).Unit
			-- A slightly skewed tangent, as produced by a smoothed root rotation.
			local tangent = (Vector3.new(-1, 0, 1).Unit + normal * 0.1).Unit
			local cframe, size = LedgeDetection.mantle_search_box(current_top, normal, tangent)
			local half = size * 0.5

			-- The search accepts inward [-2, 8], |lateral along tangent| <= 5
			-- and a rise or drop of at most 12.5 (Config.Parkour defaults).
			for _, inward in ipairs({ -2, 0, 8 }) do
				for _, lateral in ipairs({ -5, 0, 5 }) do
					for _, rise in ipairs({ -12.5, 0, 12.5 }) do
						-- Solve for the horizontal point with these inward/tangent coordinates.
						local inward_axis = -normal
						local inward_t = inward_axis:Dot(tangent)
						local right = inward_axis:Cross(Vector3.yAxis).Unit
						local right_t = right:Dot(tangent)
						local along_right = (lateral - inward * inward_t) / right_t
						local point = current_top + inward_axis * inward + right * along_right + Vector3.new(0, rise, 0)
						local relative = cframe:PointToObjectSpace(point)
						expect(math.abs(relative.X) <= half.X + 1e-4).to.equal(true)
						expect(math.abs(relative.Y) <= half.Y + 1e-4).to.equal(true)
						expect(math.abs(relative.Z) <= half.Z + 1e-4).to.equal(true)
					end
				end
			end
		end)
	end)
end
