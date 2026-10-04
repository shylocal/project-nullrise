--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local Services = ServerScriptService.server.services
local CombatFxService = require(Services.CombatFxService)
local DamageService = require(Services.DamageService)
local FakeRemote = require(TestService.support.FakeRemote)
local ServerHarness = require(TestService.support.ServerHarness)

local RADIUS = 50

type Fixture = {
	h: any,
	remote: any,
	damage: any,
	attacker_player: any,
	attacker: Model,
}

local function setup(): Fixture
	local h = ServerHarness.new()
	local remote = FakeRemote.server()
	h.Runtime:Add("DamageService", function(get)
		return DamageService.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			config = Config.Combat.Damage,
			tags = Config.World.Tags,
		})
	end)
	h.Runtime:Add("CombatFxService", function(get)
		return CombatFxService.new({
			damage = get("DamageService"),
			players = get("PlayerService"),
			remote = remote,
			config = { RelevanceRadius = RADIUS },
		})
	end)
	h:Start()

	local attacker_player = h.Players:Add({ Name = "Attacker" })
	local attacker = h:Character({ Name = "Attacker", CFrame = CFrame.new(0, 0, 0) })
	attacker_player:SetCharacter(attacker)

	return {
		h = h,
		remote = remote,
		damage = h:Get("DamageService"),
		attacker_player = attacker_player,
		attacker = attacker,
	}
end

local function hit(f: Fixture, target: Model, position: Vector3): number
	return f.damage:Apply({
		Source = { Model = f.attacker, Player = f.attacker_player },
		Target = target,
		Amount = 10,
		Kind = "Melee",
		WeaponId = "Fists",
		MoveId = 2,
		Position = position,
	})
end

local function recipients(f: Fixture): { [any]: boolean }
	local set = {}
	for _, packed in f.remote.Sent do
		set[packed[1]] = true
	end
	return set
end

return function()
	describe("CombatFxService", function()
		local f: Fixture

		afterEach(function()
			f.h:Destroy()
		end)

		it("sends the hit to nearby players with the Phase 2 payload", function()
			f = setup()
			local target = f.h:Character({ Name = "Npc", CFrame = CFrame.new(0, 0, -5) })
			local position = Vector3.new(0, 0, -5)

			hit(f, target, position)

			expect(#f.remote.Sent).to.equal(1)
			local packed = f.remote.Sent[1]
			expect(packed[1]).to.equal(f.attacker_player)
			expect(packed[2]).to.equal(Protocol.CombatFx.Hit)
			expect(packed[3]).to.equal(target)
			expect(packed[4]).to.equal(f.attacker)
			expect(packed[5]).to.equal("Fists")
			expect(packed[6]).to.equal(2)
			expect(packed[7]).to.equal(position)
			expect(packed[8]).to.equal(10)
		end)

		it("always reaches the victim and skips players beyond the radius", function()
			f = setup()
			local far_player = f.h.Players:Add({ Name = "Far" })
			far_player:SetCharacter(f.h:Character({ Name = "Far", CFrame = CFrame.new(RADIUS * 2, 0, 0) }))
			local victim_player = f.h.Players:Add({ Name = "Victim" })
			local victim = f.h:Character({ Name = "Victim", CFrame = CFrame.new(RADIUS * 4, 0, 0) })
			victim_player:SetCharacter(victim)

			hit(f, victim, Vector3.new(RADIUS * 4, 0, 0))

			local set = recipients(f)
			expect(set[victim_player]).to.equal(true)
			expect(set[far_player]).to.equal(nil)
			-- The attacker is far from where the hit landed as well.
			expect(set[f.attacker_player]).to.equal(nil)
			expect(#f.remote.Sent).to.equal(1)
		end)

		it("sends nothing for blocked damage", function()
			f = setup()
			local target = f.h:Character({ Name = "Npc", CFrame = CFrame.new(0, 0, -5) })
			target:SetAttribute(Config.World.Attributes.Invulnerable, true)

			hit(f, target, Vector3.new(0, 0, -5))

			expect(#f.remote.Sent).to.equal(0)
		end)
	end)
end
