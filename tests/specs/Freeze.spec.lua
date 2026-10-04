--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Freeze = require(ReplicatedStorage.shared.utility.Freeze)

return function()
	describe("Freeze.deep", function()
		it("freezes every nested table and returns the value", function()
			local value = { A = { B = { 1, 2 } }, C = 3 }
			expect(Freeze.deep(value)).to.equal(value)
			expect(table.isfrozen(value)).to.equal(true)
			expect(table.isfrozen(value.A)).to.equal(true)
			expect(table.isfrozen(value.A.B)).to.equal(true)
		end)

		it("handles cycles and shared references", function()
			local shared = { X = 1 }
			local value: any = { Left = shared, Right = shared }
			value.Self = value
			Freeze.deep(value)
			expect(table.isfrozen(value)).to.equal(true)
			expect(table.isfrozen(shared)).to.equal(true)
		end)

		it("walks into tables that were already frozen", function()
			local inner = { Y = 2 }
			local value = table.freeze({ Inner = inner })
			Freeze.deep(value)
			expect(table.isfrozen(inner)).to.equal(true)
		end)

		it("passes non-table values through", function()
			expect(Freeze.deep(5)).to.equal(5)
			expect(Freeze.deep(nil)).to.equal(nil)
			expect(Freeze.deep("x")).to.equal("x")
		end)
	end)

	describe("Freeze.clone_deep", function()
		it("returns an unfrozen copy with no table in common", function()
			local original = Freeze.deep({ A = { B = { 1, 2 } } })
			local copy = Freeze.clone_deep(original)
			expect(copy).never.to.equal(original)
			expect(copy.A).never.to.equal(original.A)
			expect(table.isfrozen(copy)).to.equal(false)
			expect(table.isfrozen(copy.A.B)).to.equal(false)
			expect(copy.A.B[2]).to.equal(2)
			copy.A.B[2] = 5
			expect(original.A.B[2]).to.equal(2)
		end)

		it("preserves shared references and cycles", function()
			local shared = { X = 1 }
			local value: any = { Left = shared, Right = shared }
			value.Self = value
			local copy = Freeze.clone_deep(value)
			expect(copy.Left).to.equal(copy.Right)
			expect(copy.Left).never.to.equal(shared)
			expect(copy.Self).to.equal(copy)
		end)

		it("keeps non-table leaves", function()
			local copy = Freeze.clone_deep({ Priority = Enum.AnimationPriority.Action, Id = "a", N = 1 })
			expect(copy.Priority).to.equal(Enum.AnimationPriority.Action)
			expect(copy.Id).to.equal("a")
			expect(copy.N).to.equal(1)
		end)
	end)
end
