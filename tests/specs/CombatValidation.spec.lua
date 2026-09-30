local ServerScriptService = game:GetService("ServerScriptService")
local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local CombatValidation = require(Services.CombatValidation)

return function()
	describe("CombatValidation malformed hit payloads", function()
		it("rejects a non-model target before consulting attack state", function()
			local result = CombatValidation.ValidateHit({}, nil, nil, "not a character", nil, nil)
			expect(result).to.equal(nil)
		end)

		it("rejects a non-attachment hit segment", function()
			local target = Instance.new("Model")
			local result = CombatValidation.ValidateHit({}, nil, nil, target, "not an attachment", nil)
			target:Destroy()

			expect(result).to.equal(nil)
		end)

		it("rejects non-finite hit positions", function()
			local target = Instance.new("Model")
			local invalid_position = Vector3.new(math.huge, 0, 0)
			local result = CombatValidation.ValidateHit({}, nil, nil, target, nil, invalid_position)
			target:Destroy()

			expect(result).to.equal(nil)
		end)
	end)
end
