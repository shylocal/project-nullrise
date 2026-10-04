--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local DamageService = require(ServerScriptService.server.services.DamageService)
local ServerHarness = require(TestService.support.ServerHarness)

type Fixture = {
	h: any,
	damage: any,
	attacker: Model,
	attacker_player: any,
}

local function setup(overrides: { [string]: any }?): Fixture
	local config = table.clone(Config.Combat.Damage) :: any
	if overrides then
		for key, value in overrides do
			config[key] = value
		end
	end

	local h = ServerHarness.new()
	h.Runtime:Add("DamageService", function(get)
		return DamageService.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			config = config,
			tags = Config.World.Tags,
		})
	end)
	h:Start()

	local attacker_player = h.Players:Add({ Name = "Attacker" })
	local attacker = h:Character({ Name = "Attacker" })
	attacker_player:SetCharacter(attacker)

	return {
		h = h,
		damage = h:Get("DamageService"),
		attacker = attacker,
		attacker_player = attacker_player,
	}
end

local function request(f: Fixture, target: Model, amount: number?, source: any?): any
	return {
		Source = source or { Model = f.attacker, Player = f.attacker_player },
		Target = target,
		Amount = amount or 10,
		Kind = "Melee",
		WeaponId = "Fists",
		MoveId = 2,
		Position = Vector3.zero,
	}
end

local function reason_of(_applied: number, reason: string?): string?
	return reason
end

local function record(signal: any): { { n: number, [number]: any } }
	local calls = {}
	signal:Connect(function(...)
		table.insert(calls, table.pack(...))
	end)
	return calls
end

return function()
	describe("DamageService", function()
		local f: Fixture

		afterEach(function()
			f.h:Destroy()
		end)

		it("requires every dependency", function()
			f = setup()
			expect(function()
				DamageService.new({} :: any)
			end).to.throw()
		end)

		it("applies damage, reports the applied amount and fires Damaged", function()
			f = setup()
			local target, humanoid = f.h:Character({ Name = "Target" })
			local damaged = record(f.damage.Damaged)

			local applied, reason = f.damage:Apply(request(f, target, 10))

			expect(applied).to.equal(10)
			expect(reason).to.equal(nil)
			expect(humanoid.Health).to.equal(humanoid.MaxHealth - 10)
			expect(#damaged).to.equal(1)
			expect(damaged[1][2]).to.equal(10)
			expect(damaged[1][3]).to.equal(humanoid.Health)
		end)

		it("reports only the health actually removed", function()
			f = setup()
			local target, humanoid = f.h:Character({ Name = "Target" })
			humanoid.Health = 4

			local applied = f.damage:Apply(request(f, target, 10))

			expect(applied).to.equal(4)
		end)

		it("blocks invulnerable targets and names the policy", function()
			f = setup()
			local target, humanoid = f.h:Character({ Name = "Target" })
			target:SetAttribute(Config.World.Attributes.Invulnerable, true)
			local damaged = record(f.damage.Damaged)

			local applied, reason = f.damage:Apply(request(f, target))

			expect(applied).to.equal(0)
			expect(reason).to.equal("Invulnerable")
			expect(humanoid.Health).to.equal(humanoid.MaxHealth)
			expect(#damaged).to.equal(0)
		end)

		it("runs added policies in order after the built-in ones", function()
			f = setup()
			local target = f.h:Character({ Name = "Target" })
			local order = {}
			f.damage:AddPolicy("Halve", function(_request: any, amount: number)
				table.insert(order, "Halve")
				return amount / 2, nil
			end)
			f.damage:AddPolicy("Block", function(_request, _amount)
				table.insert(order, "Block")
				return 0, nil
			end)

			local applied, reason = f.damage:Apply(request(f, target, 10))

			expect(applied).to.equal(0)
			expect(reason).to.equal("Block")
			expect(order[1]).to.equal("Halve")
			expect(order[2]).to.equal("Block")
		end)

		it("rejects duplicate policy names", function()
			f = setup()
			expect(function()
				f.damage:AddPolicy("Team", function(_request, amount)
					return amount, nil
				end)
			end).to.throw()
		end)

		it("blocks damage between players on the same team unless friendly fire is on", function()
			f = setup()
			local team = Instance.new("Team")
			local target_player = f.h.Players:Add({ Name = "Teammate" })
			local target = f.h:Character({ Name = "Teammate" })
			target_player:SetCharacter(target)
			for _, player in { f.attacker_player, target_player } do
				player.Neutral = false
				player.Team = team
			end

			local applied, reason = f.damage:Apply(request(f, target))
			expect(applied).to.equal(0)
			expect(reason).to.equal("Team")

			target_player.Neutral = true
			expect((f.damage:Apply(request(f, target)))).to.equal(10)
			team:Destroy()
		end)

		it("protects freshly spawned player characters when configured", function()
			f = setup({ SpawnProtectionSeconds = 2 })
			local target_player = f.h.Players:Add({ Name = "Spawned" })
			local target = f.h:Character({ Name = "Spawned" })
			target_player:SetCharacter(target)

			local applied, reason = f.damage:Apply(request(f, target))
			expect(applied).to.equal(0)
			expect(reason).to.equal("SpawnProtection")

			f.h.Clock:advance(2)
			expect((f.damage:Apply(request(f, target)))).to.equal(10)
		end)

		it("decides damageability from the model, its tag and the untagged rule", function()
			f = setup({ AllowUntaggedHumanoidTargets = false })
			local npc, humanoid = f.h:Character({ Name = "Npc" })
			expect((f.damage:IsDamageable(npc))).to.equal(false)
			expect(reason_of(f.damage:Apply(request(f, npc)))).to.equal("NotDamageable")

			CollectionService:AddTag(npc, Config.World.Tags.Damageable)
			local damageable, found = f.damage:IsDamageable(npc)
			expect(damageable).to.equal(true)
			expect(found).to.equal(humanoid)

			-- A player character is always damageable.
			expect((f.damage:IsDamageable(f.attacker))).to.equal(true)

			-- Nested models, plain models and the dead are not.
			local held = Instance.new("Model")
			held.Parent = npc
			expect((f.damage:IsDamageable(held))).to.equal(false)
			local prop = Instance.new("Model")
			prop.Parent = Workspace
			f.h:Track(prop)
			expect((f.damage:IsDamageable(prop))).to.equal(false)
			humanoid.Health = 0
			expect((f.damage:IsDamageable(npc))).to.equal(false)
		end)

		it("remembers distinct recent attackers within the window, newest first", function()
			f = setup({ RecentAttackerWindow = 5, RecentAttackerCount = 2 })
			local target = f.h:Character({ Name = "Target" })
			local others = {}
			for index = 1, 3 do
				others[index] = { Model = f.h:Character({ Name = "Other" .. index }), Player = nil }
			end

			f.damage:Apply(request(f, target, 1, others[1]))
			f.damage:Apply(request(f, target, 1, others[2]))
			f.damage:Apply(request(f, target, 1, others[1]))
			local recent = f.damage:GetRecentAttackers(target)
			expect(#recent).to.equal(2)
			expect(recent[1].Model).to.equal(others[1].Model)
			expect(recent[2].Model).to.equal(others[2].Model)

			f.damage:Apply(request(f, target, 1, others[3]))
			recent = f.damage:GetRecentAttackers(target)
			expect(#recent).to.equal(2)
			expect(recent[1].Model).to.equal(others[3].Model)

			f.h.Clock:advance(6)
			expect(#f.damage:GetRecentAttackers(target)).to.equal(0)
		end)

		it("fires Killed with the other recent attackers as assists", function()
			f = setup()
			local target, humanoid = f.h:Character({ Name = "Target" })
			local helper = { Model = f.h:Character({ Name = "Helper" }), Player = nil }
			local killed = record(f.damage.Killed)

			f.damage:Apply(request(f, target, 30, helper))
			expect(#killed).to.equal(0)
			f.damage:Apply(request(f, target, humanoid.Health))

			expect(#killed).to.equal(1)
			expect(killed[1][1].Source.Model).to.equal(f.attacker)
			local assists = killed[1][2]
			expect(#assists).to.equal(1)
			expect(assists[1].Model).to.equal(helper.Model)
		end)

		it("forgets a target's attackers when the target is destroyed", function()
			f = setup()
			local target = f.h:Character({ Name = "Target" })
			f.damage:Apply(request(f, target))
			expect(#f.damage:GetRecentAttackers(target)).to.equal(1)

			target:Destroy()
			task.wait()

			expect(#f.damage:GetRecentAttackers(target)).to.equal(0)
		end)

		it("rejects malformed requests", function()
			f = setup()
			local target = f.h:Character({ Name = "Target" })
			expect(reason_of(f.damage:Apply(request(f, target, -1)))).to.equal("InvalidRequest")
			expect(reason_of(f.damage:Apply(request(f, target, 0 / 0)))).to.equal("InvalidRequest")
			expect(reason_of(f.damage:Apply({} :: any))).to.equal("InvalidRequest")
		end)
	end)
end
