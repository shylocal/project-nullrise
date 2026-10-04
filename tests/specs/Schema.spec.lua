local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.shared.utility.Schema)

local function only(errors: { string }): string?
	expect(#errors).to.equal(1)
	return errors[1]
end

return function()
	describe("Schema.number", function()
		it("checks type, finiteness, integrality and bounds", function()
			expect(#Schema.check(1, Schema.number(), "N")).to.equal(0)
			expect(only(Schema.check("1", Schema.number(), "N"))).to.equal("N: must be a number")
			expect(only(Schema.check(0 / 0, Schema.number(), "N"))).to.equal("N: must be finite")
			expect(only(Schema.check(math.huge, Schema.number(), "N"))).to.equal("N: must be finite")
			expect(only(Schema.check(1.5, Schema.number({ integer = true }), "N"))).to.equal("N: must be an integer")
			expect(only(Schema.check(0, Schema.number({ gt = 0 }), "N"))).to.equal("N: must be > 0")
			expect(only(Schema.check(-1, Schema.number({ gte = 0 }), "N"))).to.equal("N: must be >= 0")
			expect(only(Schema.check(2, Schema.number({ lt = 2 }), "N"))).to.equal("N: must be < 2")
			expect(only(Schema.check(1.6, Schema.number({ lte = 1.5 }), "N"))).to.equal("N: must be <= 1.5")
			expect(#Schema.check(1.5, Schema.number({ gte = 0.5, lte = 1.5 }), "N")).to.equal(0)
		end)
	end)

	describe("Schema.string", function()
		it("checks type, emptiness, length and pattern", function()
			expect(only(Schema.check(1, Schema.string(), "S"))).to.equal("S: must be a string")
			expect(only(Schema.check("", Schema.string({ nonEmpty = true }), "S"))).to.equal("S: must not be empty")
			expect(only(Schema.check("abcd", Schema.string({ maxLength = 3 }), "S"))).to.equal(
				"S: must be at most 3 characters"
			)
			expect(only(Schema.check("x", Schema.string({ pattern = "^%d+$" }), "S"))).to.equal("S: must match ^%d+$")
			expect(#Schema.check("12", Schema.string({ pattern = "^%d+$" }), "S")).to.equal(0)
		end)
	end)

	describe("Schema scalar kinds", function()
		it("checks booleans", function()
			expect(#Schema.check(false, Schema.boolean(), "B")).to.equal(0)
			expect(only(Schema.check(nil, Schema.boolean(), "B"))).to.equal("B: must be a boolean")
		end)

		it("checks string enums", function()
			local spec = Schema.enum({ "a", "b" })
			expect(#Schema.check("a", spec, "E")).to.equal(0)
			expect(only(Schema.check("c", spec, "E"))).to.equal("E: must be one of: a, b")
		end)

		it("checks enum items by enum type", function()
			local spec = Schema.enumItem(Enum.AnimationPriority)
			expect(#Schema.check(Enum.AnimationPriority.Action, spec, "P")).to.equal(0)
			expect(only(Schema.check(Enum.KeyCode.A, spec, "P"))).to.equal("P: must be an Enum.AnimationPriority")
			expect(only(Schema.check("Action", spec, "P"))).to.equal("P: must be an Enum.AnimationPriority")
		end)

		it("allows nil for optional specs only", function()
			expect(#Schema.check(nil, Schema.optional(Schema.number()), "O")).to.equal(0)
			expect(only(Schema.check("x", Schema.optional(Schema.number()), "O"))).to.equal("O: must be a number")
		end)

		it("runs custom checks with the path", function()
			local seen_path
			local spec = Schema.custom(function(value, path)
				seen_path = path
				return if value == 1 then nil else "must be one"
			end)
			expect(#Schema.check(1, spec, "C")).to.equal(0)
			expect(only(Schema.check(2, spec, "C"))).to.equal("C: must be one")
			expect(seen_path).to.equal("C")
		end)
	end)

	describe("Schema.record", function()
		local spec = Schema.record({
			A = Schema.number(),
			B = Schema.optional(Schema.string()),
			Inner = Schema.record({ X = Schema.boolean() }),
		})

		it("collects every error with nested paths", function()
			local errors = Schema.check({ A = "x", Inner = { X = 1 }, Extra = true }, spec, "Root")
			expect(#errors).to.equal(3)
			expect(table.find(errors, "Root.A: must be a number")).to.be.ok()
			expect(table.find(errors, "Root.Inner.X: must be a boolean")).to.be.ok()
			expect(table.find(errors, "Root.Extra: unknown key")).to.be.ok()
		end)

		it("reports missing required fields", function()
			local errors = Schema.check({ Inner = {} }, spec, "Root")
			expect(table.find(errors, "Root.A: is required")).to.be.ok()
			expect(table.find(errors, "Root.Inner.X: is required")).to.be.ok()
			expect(#errors).to.equal(2)
		end)

		it("rejects non-tables", function()
			expect(only(Schema.check(5, spec, "Root"))).to.equal("Root: must be a table")
		end)

		it("allows unknown keys when open", function()
			local open = Schema.record({ A = Schema.number() }, { open = true })
			expect(#Schema.check({ A = 1, Extra = true }, open, "Root")).to.equal(0)
		end)

		it("joins paths from an empty root without a leading dot", function()
			local errors = Schema.check({ A = 1, Inner = { X = "no" } }, spec, "")
			expect(only(errors)).to.equal("Inner.X: must be a boolean")
		end)
	end)

	describe("Schema.map", function()
		it("checks keys and values", function()
			local spec = Schema.map(Schema.string({ nonEmpty = true }), Schema.number({ gte = 0 }), { nonEmpty = true })
			expect(#Schema.check({ a = 1, b = 2 }, spec, "M")).to.equal(0)
			expect(only(Schema.check({}, spec, "M"))).to.equal("M: must not be empty")
			expect(only(Schema.check({ a = -1 }, spec, "M"))).to.equal("M.a: must be >= 0")
			expect(only(Schema.check({ [1] = 1 }, spec, "M"))).to.equal("M[1]: must be a string")
			expect(only(Schema.check(true, spec, "M"))).to.equal("M: must be a table")
		end)
	end)

	describe("Schema.array", function()
		local spec = Schema.array(Schema.number(), { minLength = 2 })

		it("accepts dense arrays and checks every item", function()
			expect(#Schema.check({ 1, 2, 3 }, spec, "L")).to.equal(0)
			local errors = Schema.check({ 1, "x", "y" }, spec, "L")
			expect(#errors).to.equal(2)
			expect(errors[1]).to.equal("L[2]: must be a number")
			expect(errors[2]).to.equal("L[3]: must be a number")
		end)

		it("rejects sparse arrays and extra keys", function()
			-- Built by assignment: mixed table constructors are what the check rejects.
			local sparse: { [any]: any } = { 1, 2 }
			sparse[4] = 4
			local keyed: { [any]: any } = { 1, 2 }
			keyed.x = 3
			expect(only(Schema.check(sparse, spec, "L"))).to.equal("L: must be a dense array")
			expect(only(Schema.check(keyed, spec, "L"))).to.equal("L: must be a dense array")
		end)

		it("enforces the minimum length", function()
			expect(only(Schema.check({ 1 }, spec, "L"))).to.equal("L: must have at least 2 entries")
		end)
	end)

	describe("Schema construction", function()
		it("rejects non-spec arguments", function()
			expect(function()
				Schema.optional({} :: any)
			end).to.throw()
			expect(function()
				Schema.check(1, { kind = "nope" }, "X")
			end).to.throw()
		end)
	end)
end
