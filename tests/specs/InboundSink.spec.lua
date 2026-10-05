--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local InboundSink = require(ServerScriptService.server.network.InboundSink)
local RemoteBudget = require(ServerScriptService.server.network.RemoteBudget)
local ServerHarness = require(TestService.support.ServerHarness)

local DETAIL = "Network.UnknownAction.Weapon." .. RemoteBudget.UNKNOWN

return function()
	describe("InboundSink", function()
		local h: any

		beforeEach(function()
			h = ServerHarness.new()
			h.Runtime:Add("WeaponInbound", function(get: (string) -> any)
				return InboundSink.new({
					remote = h.Remotes.Weapon,
					name = "Weapon",
					budget = get("RemoteBudget"),
				})
			end)
			h:Start()
		end)

		afterEach(function()
			h:Destroy()
		end)

		it("requires every dependency", function()
			expect(function()
				InboundSink.new({ remote = h.Remotes.Weapon, name = "Weapon" } :: any)
			end).to.throw()
		end)

		it("drains events fired at a server-to-client remote and counts them", function()
			-- Regression: Weapon and CombatFx had no OnServerEvent listener, so
			-- the engine queued what clients fired at them and warned.
			local player = h.Players:Add()
			h.Remotes.Weapon:Inject(player, "Equipped", "Katana")
			h.Remotes.Weapon:Inject(player, { "anything" })
			h.Remotes.Weapon:Inject(player)

			expect(h:Get("Telemetry"):Snapshot()[DETAIL]).to.equal(3)
			expect(#h.Remotes.Weapon.Sent).to.equal(0)
		end)

		it("spends the sender's global budget", function()
			local player = h.Players:Add()
			local budget = h:Get("RemoteBudget")
			local global_burst = Config.Network.RemoteBudget.Global.Burst
			for _ = 1, global_burst do
				h.Remotes.Weapon:Inject(player, "x")
			end

			expect(budget:Take(player, "Combat.Attack")).to.equal(false)
		end)

		it("stops listening when destroyed", function()
			local player = h.Players:Add()
			h:Get("WeaponInbound"):Destroy()
			h.Remotes.Weapon:Inject(player, "x")

			expect(h:Get("Telemetry"):Snapshot()[DETAIL]).to.equal(nil)
		end)
	end)
end
