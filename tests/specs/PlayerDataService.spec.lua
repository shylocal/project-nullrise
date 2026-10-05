--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
local DataSchema = require(ReplicatedStorage.shared.data.Schema)
local PlayerDataService = require(ServerScriptService.server.services.PlayerDataService)
local ServerHarness = require(TestService.support.ServerHarness)
local FakeProfileStore = require(TestService.support.FakeProfileStore)

local USER_ID = 4242
local KEY = Config.Data.KeyPrefix .. tostring(USER_ID)

type Fixture = { h: any, store: any, data: any }

local function setup(is_studio: boolean): Fixture
	local h = ServerHarness.new()
	local store = FakeProfileStore.new(DataSchema.Template())
	h.Runtime:Add("PlayerDataService", function(get: (string) -> any)
		return PlayerDataService.new({
			players = get("PlayerService"),
			store = store,
			is_studio = is_studio,
			config = Config.Data,
			telemetry = get("Telemetry"),
		})
	end)
	h:Start()
	return { h = h, store = store, data = h:Get("PlayerDataService") }
end

local function join(f: Fixture): any
	return f.h.Players:Add({ UserId = USER_ID })
end

local function count(f: Fixture, reason: string): number
	return f.h:Get("Telemetry"):Snapshot()["Data." .. reason .. ".-"] or 0
end

local function slot_count(slots: { [string]: any }): number
	local n = 0
	for _ in pairs(slots) do
		n += 1
	end
	return n
end

return function()
	describe("PlayerDataService", function()
		local f: Fixture

		afterEach(function()
			if f then
				f.h:Destroy()
			end
		end)

		it("requires every dependency", function()
			expect(function()
				PlayerDataService.new({ players = {}, store = {}, is_studio = false, config = Config.Data } :: any)
			end).to.throw()
		end)

		it("starts a session, links the user id and seeds the Starter loadout once", function()
			f = setup(false)
			local player = join(f)

			local profile = f.store.Active[KEY]
			expect(profile).to.be.ok()
			expect(table.find(profile.UserIds, USER_ID)).to.be.ok()
			expect(f.data:IsPersistent(player)).to.equal(true)

			local data = f.data:GetData(player)
			expect(data).to.equal(profile.Data)
			expect(data.Version).to.equal(DataSchema.Version)
			expect(data.Inventory.Seeded).to.equal(true)

			for slot, weapon_id in Catalog.Loadout("Starter") do
				local record = data.Inventory.Slots[tostring(slot)]
				expect(record).to.be.ok()
				expect(record.ItemId).to.equal((ItemCatalog.ForWeapon(weapon_id) :: any).Id)
				expect(typeof(record.Uid)).to.equal("string")
				expect(#record.Uid > 0).to.equal(true)
			end
		end)

		it("keeps saved data and never reseeds a seeded profile", function()
			f = setup(false)
			f.store.Saved[KEY] = { Version = 1, Inventory = { Slots = {}, Seeded = true } }
			local player = join(f)

			local data = f.data:GetData(player)
			expect(data.Inventory.Seeded).to.equal(true)
			expect(slot_count(data.Inventory.Slots)).to.equal(0)
		end)

		it("reconciles missing keys from the template once the version is known", function()
			f = setup(false)
			f.store.Saved[KEY] = { Version = 1, Inventory = { Slots = {} } }
			local player = join(f)

			local data = f.data:GetData(player)
			expect(data).to.be.ok()
			expect(data.Inventory.Seeded).to.equal(true)
		end)

		it("drops corrupt slots, keeps unrecognised ones and reports the drops", function()
			f = setup(false)
			local item = ItemCatalog.Ids()[1]
			f.store.Saved[KEY] = {
				Version = 1,
				Inventory = {
					Seeded = true,
					Slots = {
						["1"] = { Uid = "a", ItemId = item, Data = {} },
						["3"] = { Uid = "a", ItemId = item, Data = {} },
						["4"] = { Uid = "b", ItemId = "MissingItem", Data = {} },
						["10"] = { Uid = "c", ItemId = item, Data = {} },
					},
				},
			}
			local player = join(f)

			local slots = f.data:GetData(player).Inventory.Slots
			expect(slots["1"]).to.be.ok()
			expect(slots["3"]).to.equal(nil)
			-- An item or slot unknown to this build is kept, and saved as it was.
			expect(slots["4"].ItemId).to.equal("MissingItem")
			expect(slots["10"].Uid).to.equal("c")
			expect(count(f, "Sanitized")).to.equal(1)

			f.h.Players:Remove(player)
			expect(f.store.Saved[KEY].Inventory.Slots["4"].ItemId).to.equal("MissingItem")
			expect(f.store.Saved[KEY].Inventory.Slots["10"].Uid).to.equal("c")
		end)

		it("kicks on a live server when the profile cannot be loaded", function()
			f = setup(false)
			f.store.Fail[KEY] = true
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.data:GetData(player)).to.equal(nil)
			expect(f.data:IsPersistent(player)).to.equal(false)
			expect(count(f, "LoadFailed")).to.equal(1)
		end)

		it("kicks on a live server when the store errors", function()
			f = setup(false)
			f.store.Error[KEY] = "DataStore unavailable"
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.data:GetData(player)).to.equal(nil)
		end)

		it("falls back to an unsaved default profile in Studio", function()
			f = setup(true)
			f.store.Fail[KEY] = true
			local player = join(f)

			expect(player.Kicked).to.equal(nil)
			local data = f.data:GetData(player)
			expect(data).to.be.ok()
			expect(data.Inventory.Seeded).to.equal(true)
			expect(f.data:IsPersistent(player)).to.equal(false)

			f.h.Players:Remove(player)
			expect(f.store.Saved[KEY]).to.equal(nil)
		end)

		it("refuses data from a newer schema without touching it", function()
			f = setup(false)
			f.store.Saved[KEY] = { Version = DataSchema.Version + 1, Inventory = { Slots = {}, Seeded = true } }
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.store.Saved[KEY].Version).to.equal(DataSchema.Version + 1)
		end)

		it("never writes to a newer profile it refuses", function()
			-- Regression: Reconcile ran before the version check, so stray
			-- template keys were added and then saved by EndSession.
			f = setup(false)
			f.store.Saved[KEY] = { Version = DataSchema.Version + 1, Wallet = { Coins = 5 } }
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			local saved = f.store.Saved[KEY]
			expect(saved.Inventory).to.equal(nil)
			expect(saved.Wallet.Coins).to.equal(5)
			expect(saved.Version).to.equal(DataSchema.Version + 1)
		end)

		it("refuses a profile without a valid Version without giving it one", function()
			f = setup(false)
			f.store.Saved[KEY] = { Inventory = { Slots = {}, Seeded = true } }
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.store.Saved[KEY].Version).to.equal(nil)
		end)

		it("releases the profile when opening it throws", function()
			-- Regression: the component never completed, so the session stayed
			-- locked and autosaved until the server closed.
			f = setup(false)
			f.store.Saved[KEY] = { Version = 1, Inventory = { Slots = {}, Seeded = true } }
			f.store.AfterStart = function(profile: any)
				profile.Reconcile = function()
					error("reconcile failed")
				end
			end
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.data:GetData(player)).to.equal(nil)
			expect(count(f, "LoadFailed")).to.equal(1)
		end)

		it("releases the profile without a steal kick when a later step throws", function()
			f = setup(false)
			f.store.AfterStart = function(profile: any)
				local signal = profile.OnSessionEnd
				profile.OnSessionEnd = {
					Connect = function()
						error("connect failed")
					end,
					Fire = function(_self: any)
						signal:Fire()
					end,
				}
			end
			local player = join(f)

			expect(player.Kicked).to.equal(PlayerDataService.LOAD_FAILED_MESSAGE)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(count(f, "SessionEnded")).to.equal(0)
		end)

		it("falls back to an unsaved profile in Studio when opening throws", function()
			f = setup(true)
			f.store.AfterStart = function(profile: any)
				profile.AddUserId = function()
					error("add user id failed")
				end
			end
			local player = join(f)

			expect(player.Kicked).to.equal(nil)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.data:GetData(player)).to.be.ok()
			expect(f.data:IsPersistent(player)).to.equal(false)
		end)

		it("passes a Cancel condition that turns true once the player leaves", function()
			f = setup(false)
			local cancelled_before: boolean? = nil
			local player: any
			f.store.BeforeReturn = function(_key, params)
				cancelled_before = params.Cancel()
				-- Players:Add fires PlayerAdded synchronously, so the load runs
				-- before Add returns and `player` is still unassigned here.
				f.h.Players:Remove(f.h.Players:GetPlayers()[1])
			end
			player = f.h.Players:Add({ UserId = USER_ID })

			expect(cancelled_before).to.equal(false)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.data:GetData(player)).to.equal(nil)
		end)

		it("ends a session that started after the player left", function()
			f = setup(false)
			f.store.IgnoreCancel = true
			local player: any
			f.store.BeforeReturn = function()
				-- Players:Add fires PlayerAdded synchronously, so the load runs
				-- before Add returns and `player` is still unassigned here.
				f.h.Players:Remove(f.h.Players:GetPlayers()[1])
			end
			player = f.h.Players:Add({ UserId = USER_ID })

			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.store.Saved[KEY]).to.be.ok()
			expect(player.Kicked).to.equal(nil)
		end)

		it("kicks when another server takes the session", function()
			f = setup(false)
			local player = join(f)

			f.store:Steal(KEY)

			expect(player.Kicked).to.equal(PlayerDataService.SESSION_ENDED_MESSAGE)
			expect(f.data:IsPersistent(player)).to.equal(false)
			expect(count(f, "SessionEnded")).to.equal(1)
		end)

		it("does not kick when the session ends because the server is closing", function()
			f = setup(false)
			local player = join(f)

			f.store.IsClosing = true
			f.store:Steal(KEY)

			expect(player.Kicked).to.equal(nil)
			expect(f.data:IsPersistent(player)).to.equal(false)
		end)

		it("saves and releases the profile when the player leaves, without a kick", function()
			f = setup(false)
			local player = join(f)
			local data = f.data:GetData(player)
			data.Inventory.Slots["5"] = { Uid = "saved-uid", ItemId = ItemCatalog.Ids()[1], Data = {} }

			f.h.Players:Remove(player)

			expect(player.Kicked).to.equal(nil)
			expect(f.store.Active[KEY]).to.equal(nil)
			expect(f.store.Saved[KEY].Inventory.Slots["5"].Uid).to.equal("saved-uid")
			expect(f.data:GetData(player)).to.equal(nil)

			-- Rejoining loads the saved items, with the same uids.
			local again = join(f)
			expect(f.data:GetData(again).Inventory.Slots["5"].Uid).to.equal("saved-uid")
		end)

		it("releases every profile when destroyed", function()
			f = setup(false)
			join(f)
			expect(f.store.Active[KEY]).to.be.ok()

			f.h:Destroy()
			expect(f.store.Active[KEY]).to.equal(nil)
			f = nil :: any
		end)
	end)
end
