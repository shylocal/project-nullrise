local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

return function()
	describe("Shared input and remote protocol", function()
		it("defines unique, nonempty action identifiers", function()
			local seen = {}
			for key, value in pairs(Actions) do
				expect(typeof(key)).to.equal("string")
				expect(typeof(value)).to.equal("string")
				expect(value ~= "").to.equal(true)
				expect(seen[value]).to.equal(nil)
				seen[value] = key
			end
		end)

		it("defines unique, nonempty remote action names", function()
			local seen = {}
			for domain, actions in pairs(Protocol) do
				expect(typeof(domain)).to.equal("string")
				expect(typeof(actions)).to.equal("table")
				for key, value in pairs(actions) do
					expect(typeof(key)).to.equal("string")
					expect(typeof(value)).to.equal("string")
					expect(value ~= "").to.equal(true)
					expect(seen[value]).to.equal(nil)
					seen[value] = domain .. "." .. key
				end
			end
		end)
	end)
end
