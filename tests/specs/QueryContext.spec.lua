--!strict
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Parkour = StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController
local Metrics = require(Parkour.Metrics)
local QueryContext = require(Parkour.QueryContext)

local ORIGIN = Vector3.new(-60000, 300, -60000)

local function make_wall(name, z, parent)
	local wall = Instance.new("Part")
	wall.Name = name
	wall.Anchored = true
	wall.Size = Vector3.new(4, 4, 0.5)
	wall.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 0, z))
	wall.Parent = parent
	return wall
end

return function()
	describe("Parkour QueryContext", function()
		local container
		local character
		local controller
		local ctx
		local near
		local middle
		local far

		beforeEach(function()
			container = Instance.new("Folder")
			container.Name = "QueryContextSpec"
			container.Parent = Workspace
			character = Instance.new("Model")
			character.Parent = container
			-- Walls along -Z from the origin: near (z=-2), middle (z=-4), far (z=-6).
			near = make_wall("Near", -2, container)
			middle = make_wall("Middle", -4, container)
			far = make_wall("Far", -6, container)
			controller = { Character = character, Metrics = Metrics.new(true) }
			ctx = QueryContext.new(controller)
		end)

		afterEach(function()
			container:Destroy()
		end)

		local function pierce(classify, max_hits)
			return ctx:Pierce(ORIGIN, Vector3.new(0, 0, -10), ctx.Params.CastAny, classify, max_hits)
		end

		it("accepts the first hit the classifier accepts", function()
			local seen = {}
			local hit = pierce(function(result)
				table.insert(seen, result.Instance)
				return if result.Instance == middle then "accept" else "skip"
			end, 8)
			expect((hit :: RaycastResult).Instance).to.equal(middle)
			expect(#seen).to.equal(2)
			expect(seen[1]).to.equal(near)
		end)

		it("stops without a result when the classifier says stop", function()
			local hit = pierce(function()
				return "stop"
			end, 8)
			expect(hit).to.equal(nil)
			expect(Metrics.snapshot(controller).Raycasts).to.equal(1)
		end)

		it("returns nil when every hit is skipped or the ray runs out", function()
			local hit = pierce(function()
				return "skip"
			end, 8)
			expect(hit).to.equal(nil)
			-- Three walls plus the final miss.
			expect(Metrics.snapshot(controller).Raycasts).to.equal(4)
		end)

		it("casts at most max_hits times", function()
			local hit = pierce(function()
				return "skip"
			end, 2)
			expect(hit).to.equal(nil)
			expect(Metrics.snapshot(controller).Raycasts).to.equal(2)
		end)

		it("resets the filter to its base list on every pierce", function()
			pierce(function()
				return "skip"
			end, 8)
			local hit = pierce(function()
				return "accept"
			end, 8)
			expect((hit :: RaycastResult).Instance).to.equal(near)
		end)

		it("always excludes the character", function()
			local body = make_wall("Body", -1, character)
			local hit = ctx:Raycast(ORIGIN, Vector3.new(0, 0, -10), ctx.Params.CastAny)
			expect((hit :: RaycastResult).Instance).to.equal(near)
			body:Destroy()
		end)

		it("records an extra named metric and the frame ray count", function()
			Metrics.begin_frame(controller)
			ctx:Raycast(ORIGIN, Vector3.new(0, 0, -10), ctx.Params.CastAny, "GuideTopRaycasts")
			local snapshot = Metrics.snapshot(controller)
			expect(snapshot.Raycasts).to.equal(1)
			expect(snapshot.GuideTopRaycasts).to.equal(1)
			expect(snapshot.RaysThisFrame).to.equal(1)
		end)

		it("restricts Include params to one instance", function()
			local params = ctx:Include(ctx.Params.GuideTop, far)
			local hit = ctx:Raycast(ORIGIN, Vector3.new(0, 0, -10), params)
			expect((hit :: RaycastResult).Instance).to.equal(far)
		end)

		it("adds extra exclusions on top of the base list", function()
			local params = ctx:Exclude(ctx.Params.VaultSupport, { near })
			local hit = ctx:Raycast(ORIGIN, Vector3.new(0, 0, -10), params)
			expect((hit :: RaycastResult).Instance).to.equal(middle)
		end)

		it("counts overlap queries", function()
			ctx:PartBoundsInBox(CFrame.new(ORIGIN + Vector3.new(0, 0, -2)), Vector3.one, ctx.Overlap.Vault)
			expect(Metrics.snapshot(controller).OverlapQueries).to.equal(1)
		end)
	end)
end
