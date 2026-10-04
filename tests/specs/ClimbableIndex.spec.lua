--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.packages.Signal)
local Config = require(ReplicatedStorage.shared.config)
local ClimbableIndex = require(StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController.ClimbableIndex)

local ORIGIN = Vector3.new(50000, 200, 50000)

type Signal = typeof(Signal.new())

-- A CollectionService stand-in whose Added / Removed signals specs fire.
type FakeCollection = {
	Tagged: { Instance },
	Added: Signal,
	Removed: Signal,
	GetTagged: (self: FakeCollection, tag: string) -> { Instance },
	GetInstanceAddedSignal: (self: FakeCollection, tag: string) -> Signal,
	GetInstanceRemovedSignal: (self: FakeCollection, tag: string) -> Signal,
}

local function make_collection(tagged: { Instance }): FakeCollection
	return {
		Tagged = tagged,
		Added = Signal.new(),
		Removed = Signal.new(),
		GetTagged = function(self: FakeCollection, _tag: string): { Instance }
			return self.Tagged
		end,
		GetInstanceAddedSignal = function(self: FakeCollection, _tag: string): Signal
			return self.Added
		end,
		GetInstanceRemovedSignal = function(self: FakeCollection, _tag: string): Signal
			return self.Removed
		end,
	}
end

local function make_part(name: string, position: Vector3, size: Vector3?, parent: Instance?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size or Vector3.new(4, 1, 4)
	part.CFrame = CFrame.new(ORIGIN + position)
	part.Parent = parent or Workspace
	return part
end

return function()
	describe("ClimbableIndex", function()
		local container: Folder
		local built_index: ClimbableIndex.ClimbableIndex?

		beforeEach(function()
			container = Instance.new("Folder")
			container.Name = "ClimbableIndexSpec"
			container.Parent = Workspace
		end)

		afterEach(function()
			local built = built_index
			if built then
				built:Destroy()
				built_index = nil
			end
			container:Destroy()
		end)

		-- Returns the fake collection and the index over it.
		local function build(tagged: { Instance }): (FakeCollection, ClimbableIndex.ClimbableIndex)
			local collection = make_collection(tagged)
			local built = ClimbableIndex.new({
				collection = collection,
				tag = "Climbable",
				cell_size = 16,
				root = Workspace,
			})
			built_index = built
			return collection, built
		end

		it("requires every dependency", function()
			expect(function()
				ClimbableIndex.new({ collection = make_collection({}), tag = "Climbable", root = Workspace } :: any)
			end).to.throw()
		end)

		it("indexes only tagged guides under the root", function()
			local inside = make_part("Inside", Vector3.zero, nil, container)
			local outside = Instance.new("Part")
			outside.Parent = ReplicatedStorage
			local _, index = build({ inside, outside })

			expect(index:IsClimbable(inside)).to.equal(true)
			expect(index:IsClimbable(outside)).to.equal(false)
			outside:Destroy()
		end)

		it("resolves a descendant to its nearest tagged ancestor", function()
			local model = Instance.new("Model")
			model.Parent = container
			local child = make_part("Child", Vector3.zero, nil, model)
			local untagged = make_part("Untagged", Vector3.new(20, 0, 0), nil, container)
			local _, index = build({ model })

			expect(index:GuideOf(child)).to.equal(model)
			expect(index:GuideOf(model)).to.equal(model)
			expect(index:GuideOf(untagged)).to.equal(nil)
			expect(index:GuideOf(nil)).to.equal(nil)
		end)

		it("returns only guides whose bounds overlap the query box", function()
			local near = make_part("Near", Vector3.zero, nil, container)
			local far = make_part("Far", Vector3.new(200, 0, 0), nil, container)
			local _, index = build({ near, far })

			local hits = index:QueryBox(CFrame.new(ORIGIN + Vector3.new(3, 0, 0)), Vector3.new(4, 4, 4))
			expect(#hits).to.equal(1)
			expect(hits[1]).to.equal(near)

			local none = index:QueryBox(CFrame.new(ORIGIN + Vector3.new(100, 0, 0)), Vector3.new(4, 4, 4))
			expect(#none).to.equal(0)
		end)

		it("uses the oriented box's world bounds", function()
			local guide = make_part("Rotated", Vector3.new(0, 0, 9), nil, container)
			local _, index = build({ guide })
			-- A 2x2x20 box rotated 90 degrees about Y spans X, not Z.
			local rotated = CFrame.new(ORIGIN) * CFrame.Angles(0, math.rad(90), 0)
			expect(#index:QueryBox(rotated, Vector3.new(2, 2, 20))).to.equal(0)
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.new(2, 2, 20))).to.equal(1)
		end)

		it("tracks tags added and removed after construction", function()
			local collection, index = build({})
			local guide = make_part("Late", Vector3.zero, nil, container)
			expect(index:IsClimbable(guide)).to.equal(false)

			collection.Added:Fire(guide)
			expect(index:IsClimbable(guide)).to.equal(true)
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(1)

			collection.Removed:Fire(guide)
			expect(index:IsClimbable(guide)).to.equal(false)
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(0)
		end)

		it("caches part and model bounds", function()
			local part = make_part("Part", Vector3.zero, Vector3.new(4, 2, 6), container)
			local model = Instance.new("Model")
			model.Parent = container
			make_part("A", Vector3.new(20, 0, 0), Vector3.new(2, 2, 2), model)
			make_part("B", Vector3.new(30, 0, 0), Vector3.new(2, 2, 2), model)
			local _, index = build({ part, model })

			local cframe, size = index:Bounds(part)
			expect(cframe).to.equal(part.CFrame)
			expect(size).to.equal(part.Size)
			local model_cframe, model_size = index:Bounds(model)
			expect((model_cframe.Position - (ORIGIN + Vector3.new(25, 0, 0))).Magnitude < 1e-3).to.equal(true)
			expect(math.abs(model_size.X - 12) < 1e-3).to.equal(true)
		end)

		it("re-measures a ClimbableDynamic guide on every query", function()
			local mover = make_part("Mover", Vector3.zero, nil, container)
			mover:SetAttribute(Config.World.Attributes.ClimbableDynamic, true)
			local _, index = build({ mover })

			mover.CFrame = CFrame.new(ORIGIN + Vector3.new(500, 0, 0))
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(0)
			local hits = index:QueryBox(CFrame.new(ORIGIN + Vector3.new(500, 0, 0)), Vector3.one)
			expect(hits[1]).to.equal(mover)
			local _, size = index:Bounds(mover)
			expect(size).to.equal(mover.Size)
		end)

		it("re-measures a Model guide moved by PivotTo", function()
			local model = Instance.new("Model")
			model.Parent = container
			make_part("A", Vector3.zero, Vector3.new(2, 2, 2), model)
			make_part("B", Vector3.new(4, 0, 0), Vector3.new(2, 2, 2), model)
			local _, index = build({ model })
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(1)

			-- No descendant is added or removed, so only the pivot check sees this.
			model:PivotTo(model:GetPivot() + Vector3.new(0, 300, 0))
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(0)
			local hits = index:QueryBox(CFrame.new(ORIGIN + Vector3.new(0, 300, 0)), Vector3.one)
			expect(hits[1]).to.equal(model)

			model:PivotTo(model:GetPivot() + Vector3.new(0, 50, 0))
			local cframe = index:Bounds(model)
			expect((cframe.Position - (ORIGIN + Vector3.new(2, 350, 0))).Magnitude < 1e-3).to.equal(true)
		end)

		it("re-measures a Model guide whose parts are moved directly", function()
			local model = Instance.new("Model")
			model.Parent = container
			local only = make_part("Only", Vector3.zero, Vector3.new(2, 2, 2), model)
			local _, index = build({ model })

			-- Without a PrimaryPart the pivot stays put; the reference part moves.
			only.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 300, 0))
			expect(#index:QueryBox(CFrame.new(ORIGIN), Vector3.one)).to.equal(0)
			expect(#index:QueryBox(CFrame.new(ORIGIN + Vector3.new(0, 300, 0)), Vector3.one)).to.equal(1)
		end)

		it("measures a Model with an unanchored part live", function()
			local model = Instance.new("Model")
			model.Parent = container
			make_part("Anchored", Vector3.zero, Vector3.new(2, 2, 2), model)
			local loose = make_part("Loose", Vector3.new(4, 0, 0), Vector3.new(2, 2, 2), model)
			loose.Anchored = false
			local _, index = build({ model })

			-- Moving a non-reference part with no signal is still seen live.
			loose.CFrame = CFrame.new(ORIGIN + Vector3.new(40, 0, 0))
			expect(#index:QueryBox(CFrame.new(ORIGIN + Vector3.new(40, 0, 0)), Vector3.one)).to.equal(1)
		end)

		it("keeps very large guides queryable", function()
			local huge = make_part("Huge", Vector3.zero, Vector3.new(2000, 1, 2000), container)
			local _, index = build({ huge })
			local hits = index:QueryBox(CFrame.new(ORIGIN + Vector3.new(900, 0, -900)), Vector3.one)
			expect(hits[1]).to.equal(huge)
		end)

		it("forgets everything on Destroy", function()
			local guide = make_part("Guide", Vector3.zero, nil, container)
			local collection, index = build({ guide })
			index:Destroy()
			expect(index:IsClimbable(guide)).to.equal(false)
			collection.Added:Fire(guide)
			expect(index:IsClimbable(guide)).to.equal(false)
		end)
	end)
end
