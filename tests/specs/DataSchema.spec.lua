--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
local DataSchema = require(ReplicatedStorage.shared.data.Schema)

local ITEM = ItemCatalog.Ids()[1]

local function record(uid: string, item_id: string?): any
	return { Uid = uid, ItemId = item_id or ITEM, Data = {} }
end

return function()
	describe("Data Schema", function()
		it("builds a fresh template at the current version", function()
			local a = DataSchema.Template()
			local b = DataSchema.Template()
			expect(a.Version).to.equal(DataSchema.Version)
			expect(a.Inventory.Seeded).to.equal(false)
			expect((next(a.Inventory.Slots))).to.equal(nil)
			expect(a).never.to.equal(b)
			expect(a.Inventory).never.to.equal(b.Inventory)
		end)

		it("accepts current data unchanged", function()
			local data = DataSchema.Template()
			local migrated, err = DataSchema.migrate(data)
			expect(err).to.equal(nil)
			expect(migrated).to.equal(data)
		end)

		it("rejects data it cannot read", function()
			local cases: { any } = {
				nil,
				"data",
				{},
				{ Version = 0, Inventory = { Slots = {}, Seeded = false } },
				{ Version = 1.5, Inventory = { Slots = {}, Seeded = false } },
				{ Version = DataSchema.Version + 1, Inventory = { Slots = {}, Seeded = false } },
				{ Version = 1 },
				{ Version = 1, Inventory = { Seeded = false } },
				{ Version = 1, Inventory = { Slots = {}, Seeded = "yes" } },
			}
			for index = 1, 9 do
				local migrated, err = DataSchema.migrate(cases[index])
				expect(migrated).to.equal(nil)
				expect(typeof(err)).to.equal("string")
			end
		end)

		it("runs the migration chain in order and bumps Version per step", function()
			local order = {}
			local migrations = {
				[1] = function(data: any)
					table.insert(order, 1)
					data.Added = true
				end,
				[2] = function(data: any)
					table.insert(order, 2)
					expect(data.Version).to.equal(2)
				end,
			}
			local data: any = { Version = 1 }
			local migrated, err = DataSchema.run_migrations(data, migrations, 3)

			expect(err).to.equal(nil)
			expect(migrated).to.equal(data)
			expect(data.Version).to.equal(3)
			expect(data.Added).to.equal(true)
			expect(order[1]).to.equal(1)
			expect(order[2]).to.equal(2)
		end)

		it("fails on a missing or erroring migration step", function()
			local _, missing = DataSchema.run_migrations({ Version = 1 }, {}, 2)
			expect(typeof(missing)).to.equal("string")

			local _, failed = DataSchema.run_migrations({ Version = 1 }, {
				[1] = function()
					error("boom")
				end,
			}, 2)
			expect(typeof(failed)).to.equal("string")
		end)

		it("sanitizes slot keys, records, unknown items and duplicate uids", function()
			local data: any = DataSchema.Template()
			local slots = data.Inventory.Slots
			slots["1"] = record("keep-1")
			slots["2"] = record("keep-1")
			slots["3"] = record("unknown", "MissingItem")
			slots["4"] = { Uid = "", ItemId = ITEM, Data = {} }
			slots["5"] = { Uid = "no-data", ItemId = ITEM }
			slots["6"] = "not a record"
			slots["0"] = record("zero")
			slots["10"] = record("ten")
			slots["01"] = record("padded")
			slots["x"] = record("named")
			slots["9"] = record("keep-9")

			local warnings = DataSchema.sanitize(data, 9)

			expect(#warnings).to.equal(9)
			expect(slots["1"].Uid).to.equal("keep-1")
			expect(slots["9"].Uid).to.equal("keep-9")
			local remaining = 0
			for _ in pairs(slots) do
				remaining += 1
			end
			expect(remaining).to.equal(2)
		end)

		it("keeps the lower slot when a uid repeats", function()
			local data: any = DataSchema.Template()
			data.Inventory.Slots["7"] = record("dup")
			data.Inventory.Slots["2"] = record("dup")

			DataSchema.sanitize(data, 9)

			expect(data.Inventory.Slots["2"]).to.be.ok()
			expect(data.Inventory.Slots["7"]).to.equal(nil)
		end)

		it("respects the slot limit it is given", function()
			local data: any = DataSchema.Template()
			data.Inventory.Slots["4"] = record("four")

			expect(#DataSchema.sanitize(data, 3)).to.equal(1)
			expect(data.Inventory.Slots["4"]).to.equal(nil)
		end)
	end)
end
