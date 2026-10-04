--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Config = require(ReplicatedStorage.shared.config)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

return function()
	describe("Shared input actions", function()
		it("defines unique, nonempty action identifiers", function()
			local seen = {}
			for key, value in pairs(Actions) do
				if key ~= "Slots" and key ~= "slot_index" then
					expect(typeof(key)).to.equal("string")
					expect(typeof(value)).to.equal("string")
					expect(value ~= "").to.equal(true)
					expect(seen[value]).to.equal(nil)
					seen[value] = key
				end
			end
		end)

		it("generates one slot action per inventory slot", function()
			expect(#Actions.Slots).to.equal(Config.Inventory.MaxSlots)
			expect(table.isfrozen(Actions.Slots)).to.equal(true)
			for index, name in ipairs(Actions.Slots) do
				expect(name).to.equal("Slot" .. index)
				expect((Actions :: any)[name]).to.equal(name)
				expect(Actions.slot_index(name)).to.equal(index)
			end
			expect(Actions.Slot1).to.equal("Slot1")
			expect(Actions.Slot2).to.equal("Slot2")
		end)

		it("returns nil slot indices for non-slot actions", function()
			expect(Actions.slot_index("Primary")).to.equal(nil)
			expect(Actions.slot_index("Slot0")).to.equal(nil)
			expect(Actions.slot_index("Slot" .. (Config.Inventory.MaxSlots + 1))).to.equal(nil)
			expect(Actions.slot_index("slot1")).to.equal(nil)
		end)
	end)

	describe("Shared remote protocol", function()
		it("defines unique, nonempty action names within each remote", function()
			for domain, actions in pairs(Protocol) do
				expect(typeof(domain)).to.equal("string")
				expect(typeof(actions)).to.equal("table")
				local seen = {}
				for key, value in pairs(actions) do
					expect(typeof(key)).to.equal("string")
					expect(typeof(value)).to.equal("string")
					expect(value ~= "").to.equal(true)
					expect(seen[value]).to.equal(nil)
					seen[value] = key
				end
			end
		end)

		it("keeps the Phase 2 wire names", function()
			expect(Protocol.Combat.Attack).to.equal("Attack")
			expect(Protocol.Combat.HitStart).to.equal("HitStart")
			expect(Protocol.Combat.HitStop).to.equal("HitStop")
			expect(Protocol.Combat.Hit).to.equal("Hit")
			expect(Protocol.Combat.AttackAccepted).to.equal("AttackAccepted")
			expect(Protocol.Combat.AttackRejected).to.equal("AttackRejected")
			expect(Protocol.Combat.HitConfirmed).to.equal("HitConfirmed")
			expect(Protocol.Inventory.SelectSlot).to.equal("SelectSlot")
			expect(Protocol.Inventory.SelectUid).to.equal("SelectUid")
			expect(Protocol.Inventory.Changed).to.equal("Changed")
			expect(Protocol.Weapon.Equipped).to.equal("Equipped")
			expect(Protocol.CombatFx.Hit).to.equal("Hit")
		end)

		it("has no separate Charge action (charges are moves)", function()
			expect((Protocol.Combat :: any).Charge).to.equal(nil)
			expect(Config.Network.RemoteBudget.Actions["Combat.Charge"]).to.equal(nil)
		end)

		it("is frozen", function()
			expect(table.isfrozen(Protocol)).to.equal(true)
			for _, actions in pairs(Protocol) do
				expect(table.isfrozen(actions)).to.equal(true)
			end
		end)

		it("has a budget for every client-to-server action", function()
			local actions = Config.Network.RemoteBudget.Actions
			for _, name in ipairs({ "Attack", "HitStart", "HitStop", "Hit" }) do
				expect(actions["Combat." .. Protocol.Combat[name]]).to.be.ok()
			end
			for _, name in ipairs({ "SelectSlot", "SelectUid" }) do
				expect(actions["Inventory." .. Protocol.Inventory[name]]).to.be.ok()
			end
		end)
	end)
end
