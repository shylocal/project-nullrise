--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Packages = ReplicatedStorage.packages
local Signal = require(Packages.Signal)
local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local CombatService = require(ServerScriptService.server.services.CombatService)
local ServerHarness = require(TestService.support.ServerHarness)

local Actions = Protocol.Combat
local DEFAULT_WEAPON = Catalog.Get(Catalog.DefaultId) :: any

-- Deep enough copy of a catalog weapon to tweak one attack's numbers.
local function copy_weapon(weapon: any): any
	local copy = table.clone(weapon)
	copy.Attacks = table.clone(weapon.Attacks)
	for index, attack: any in copy.Attacks do
		copy.Attacks[index] = table.clone(attack :: any)
	end
	if weapon.Charge then
		copy.Charge = table.clone(weapon.Charge)
	end
	return copy
end

type Fixture = {
	h: any,
	remote: any,
	weapons: any,
	service: any,
	player: any,
	character: Model,
	humanoid: Humanoid,
	wielded: BasePart,
	hitpoint: Attachment,
}

-- Attacker at the origin facing -Z with a wielded part 3 studs ahead that
-- carries a tagged hitpoint.
local function setup(): Fixture
	local h = ServerHarness.new()
	local remote = h.Remotes.Combat
	local weapons = {
		EquippedChanged = Signal.new(),
		Weapon = DEFAULT_WEAPON,
		Wielded = nil :: BasePart?,
	}
	function weapons.GetEquipped(self: any, _player: any)
		return self.Weapon
	end
	function weapons.GetWielded(self: any, _player: any, _name: string)
		return self.Wielded
	end
	function weapons.Destroy(self: any)
		self.EquippedChanged:DisconnectAll()
	end

	h.Runtime:Add("Weapons", function()
		return weapons
	end)
	h.Runtime:Add("CombatService", function(get)
		return CombatService.new({
			players = get("PlayerService"),
			weapons = get("Weapons"),
			remote = remote,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
			scheduler = h.Clock:scheduler(),
		})
	end)
	h:Start()

	local character, humanoid = h:Character({
		Name = "Attacker",
		CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1)),
	})
	local wielded = Instance.new("Part")
	wielded.Name = "SpecWielded"
	wielded.Anchored = true
	wielded.CanCollide = false
	wielded.CFrame = CFrame.new(0, 0, -3)
	wielded.Parent = character
	local hitpoint = Instance.new("Attachment")
	hitpoint.Name = Config.World.Names.HitpointAttachment
	hitpoint.Parent = wielded
	CollectionService:AddTag(hitpoint, Config.World.Tags.Hitpoint)
	weapons.Wielded = wielded

	local player = h.Players:Add()
	player:SetCharacter(character)

	return {
		h = h,
		remote = remote,
		weapons = weapons,
		service = h:Get("CombatService"),
		player = player,
		character = character,
		humanoid = humanoid,
		wielded = wielded,
		hitpoint = hitpoint,
	}
end

local function state_of(f: Fixture): any
	return f.h:Get("PlayerService"):Get(f.player):Get(f.service)
end

local function last_reply(f: Fixture): any
	return f.remote.Sent[#f.remote.Sent]
end

local function replies(f: Fixture, action: string): number
	local count = 0
	for _, packed in f.remote.Sent do
		if packed[2] == action then
			count += 1
		end
	end
	return count
end

local function send(f: Fixture, ...: any)
	f.remote:Inject(f.player, ...)
end

local function snapshot(f: Fixture, key: string): number?
	return f.h:Get("Telemetry"):Snapshot()[key]
end

local function make_target(f: Fixture, position: Vector3): (Model, Humanoid)
	local target, humanoid = f.h:Character({ Name = "Target", CFrame = CFrame.new(position) })
	return target, humanoid
end

return function()
	describe("CombatService attack requests", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		it("accepts an attack and replies with the next combo index", function()
			send(f, Actions.Attack, 1)

			local reply = last_reply(f)
			expect(#f.remote.Sent).to.equal(1)
			expect(reply[1]).to.equal(f.player)
			expect(reply[2]).to.equal(Actions.AttackAccepted)
			expect(reply[3]).to.equal(1)
			expect(reply[4]).to.equal(2)
			expect(state_of(f).Active.AttackIndex).to.equal(1)
		end)

		it("rejects a new attack before the previous attack's MinDuration", function()
			send(f, Actions.Attack, 1)
			local first_active = state_of(f).Active
			f.h.Clock:advance(0.05)
			send(f, Actions.Attack, 2)

			expect(#f.remote.Sent).to.equal(2)
			expect(last_reply(f)[2]).to.equal(Actions.AttackRejected)
			expect(last_reply(f)[3]).to.equal(2)
			expect(last_reply(f)[4]).to.equal(2)
			expect(state_of(f).Active).to.equal(first_active)
		end)

		it("accepts the next attack once MinDuration has elapsed and wraps the combo", function()
			local min_duration = DEFAULT_WEAPON.Attacks[1].MinDuration
			send(f, Actions.Attack, 1)
			f.h.Clock:advance(min_duration)
			send(f, Actions.Attack, 2)

			local reply = last_reply(f)
			expect(reply[2]).to.equal(Actions.AttackAccepted)
			expect(reply[3]).to.equal(2)
			expect(reply[4]).to.equal(#DEFAULT_WEAPON.Attacks == 2 and 1 or 3)
		end)

		it("rejects an out-of-sequence attack index", function()
			send(f, Actions.Attack, 2)

			expect(last_reply(f)[2]).to.equal(Actions.AttackRejected)
			expect(last_reply(f)[4]).to.equal(1)
		end)

		it("rejects when the attacker has no character", function()
			f.player:SetCharacter(nil)
			send(f, Actions.Attack, 1)

			local reply = last_reply(f)
			expect(#f.remote.Sent).to.equal(1)
			expect(reply[2]).to.equal(Actions.AttackRejected)
			expect(reply[3]).to.equal(1)
			expect(snapshot(f, "Combat.AttackerInvalid." .. DEFAULT_WEAPON.Id)).to.equal(1)
		end)

		it("rejects malformed attack indices without echoing them, at most once per interval", function()
			for _ = 1, 3 do
				send(f, Actions.Attack, 1.5)
			end

			expect(#f.remote.Sent).to.equal(1)
			expect(last_reply(f)[2]).to.equal(Actions.AttackRejected)
			expect(last_reply(f)[3]).to.equal(nil)
			expect(snapshot(f, "Combat.BadPayload." .. DEFAULT_WEAPON.Id)).to.equal(3)

			f.h.Clock:advance(Config.Combat.RejectReplyInterval)
			send(f, Actions.Attack, "x")
			expect(#f.remote.Sent).to.equal(2)
		end)

		it("does not amplify a flood of budget-dropped attacks", function()
			for _ = 1, 20 do
				send(f, Actions.Attack, 1)
			end

			-- One accept, then rejects for each request that passed the budget
			-- (Burst), then at most one throttled reject for the dropped rest.
			local burst = Config.Network.RemoteBudget.Actions["Combat.Attack"].Burst
			expect(replies(f, Actions.AttackAccepted)).to.equal(1)
			expect(replies(f, Actions.AttackRejected)).to.equal(burst - 1 + 1)
			expect((snapshot(f, "Network.RateLimited.Combat.Attack") or 0) > 0).to.equal(true)

			-- Within the reply interval, further dropped requests stay silent.
			local before = #f.remote.Sent
			f.h.Clock:advance(Config.Combat.RejectReplyInterval / 2)
			for _ = 1, 20 do
				send(f, Actions.Attack, 7)
			end
			local window_replies = #f.remote.Sent - before
			-- At most the refilled budget's normal rejects plus one throttled reply.
			expect(window_replies <= 2).to.equal(true)
		end)

		it("counts non-string actions as bad payloads and ignores unknown actions", function()
			send(f, 42)
			send(f, "Bogus", 1)

			expect(#f.remote.Sent).to.equal(0)
			expect(snapshot(f, "Network.BadPayload.Combat")).to.equal(1)
			expect(snapshot(f, "Network.UnknownAction.Combat.Bogus")).to.equal(1)
		end)

		it("resets the combo but not the cooldown when the equipped weapon changes", function()
			send(f, Actions.Attack, 1)
			local state = state_of(f)
			local next_attack_at = state.NextAttackAt

			f.weapons.EquippedChanged:Fire(f.player, DEFAULT_WEAPON)

			expect(state.Active).to.equal(nil)
			expect(state.NextAttack).to.equal(1)
			expect(state.NextAttackAt).to.equal(next_attack_at)
		end)

		it("resets the combo and the cooldown when the character is removed", function()
			send(f, Actions.Attack, 1)
			local state = state_of(f)

			f.player:SetCharacter(nil)

			expect(state.Active).to.equal(nil)
			expect(state.NextAttack).to.equal(1)
			expect(state.NextAttackAt).to.equal(nil)
		end)
	end)

	describe("CombatService hit lifecycle", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		-- Steps past the open edge of the HitStart window (which sits at the
		-- attack start for these weapons) before sending, so float rounding
		-- of the window edge cannot make the packet early.
		local function start_hit(attack_key: any)
			f.h.Clock:advance(0.0625)
			send(f, Actions.HitStart, attack_key)
		end

		it("applies damage once per target and confirms it", function()
			local target, humanoid = make_target(f, Vector3.new(0, 0, -6))
			send(f, Actions.Attack, 1)
			start_hit(1)

			send(f, Actions.Hit, 1, target, f.hitpoint, Vector3.new(0, 0, -6))
			send(f, Actions.Hit, 1, target, f.hitpoint, Vector3.new(0, 0, -6))

			expect(humanoid.Health).to.equal(humanoid.MaxHealth - DEFAULT_WEAPON.Attacks[1].Damage)
			expect(replies(f, Actions.HitConfirmed)).to.equal(1)
			expect(last_reply(f)[3]).to.equal(1)
			expect(last_reply(f)[4]).to.equal(target)
			expect(snapshot(f, "Combat.Duplicate." .. DEFAULT_WEAPON.Id)).to.equal(1)
		end)

		it("stops validating a target after MaxRejectsPerTarget failures", function()
			-- Behind the attacker, far from the hitpoint: every validation fails.
			local target = make_target(f, Vector3.new(0, 0, 6))
			send(f, Actions.Attack, 1)
			start_hit(1)

			for _ = 1, Config.Combat.MaxRejectsPerTarget + 3 do
				send(f, Actions.Hit, 1, target, f.hitpoint, Vector3.new(0, 0, 4))
			end

			local reasons = 0
			for key, count in f.h:Get("Telemetry"):Snapshot() do
				if key ~= "Combat.RejectLimit." .. DEFAULT_WEAPON.Id and string.sub(key, 1, 7) == "Combat." then
					reasons += count
				end
			end
			expect(reasons).to.equal(Config.Combat.MaxRejectsPerTarget)
			expect(snapshot(f, "Combat.RejectLimit." .. DEFAULT_WEAPON.Id)).to.equal(3)
			expect(state_of(f).Active.HitRequests).to.equal(Config.Combat.MaxRejectsPerTarget)
		end)

		it("ignores hits before HitStart", function()
			local target, humanoid = make_target(f, Vector3.new(0, 0, -6))
			send(f, Actions.Attack, 1)

			send(f, Actions.Hit, 1, target, f.hitpoint, Vector3.new(0, 0, -6))

			expect(humanoid.Health).to.equal(humanoid.MaxHealth)
			expect(snapshot(f, "Combat.NotActive." .. DEFAULT_WEAPON.Id)).to.equal(1)
		end)

		it("ignores and counts a HitStart before the definition's HitStartAt", function()
			local weapon = copy_weapon(DEFAULT_WEAPON)
			weapon.Attacks[1].HitStartAt = 5
			f.weapons.Weapon = weapon
			send(f, Actions.Attack, 1)

			start_hit(1)

			local active = state_of(f).Active
			expect(active).to.be.ok()
			expect(active.HitActive).to.equal(false)
			expect(snapshot(f, "Combat.EarlyHitStart." .. weapon.Id)).to.equal(1)
		end)

		it("clears a light attack whose HitStart arrives after its window", function()
			local attack = DEFAULT_WEAPON.Attacks[1]
			send(f, Actions.Attack, 1)
			f.h.Clock:advance((attack.HitStartAt + attack.HitWindow) / 2)
			local active = state_of(f).Active
			-- Expiry would clear it first; check the late path directly by
			-- moving its closing time.
			active.HitStartClosesAt = f.h.Clock.now() - 0.01

			start_hit(1)

			expect(state_of(f).Active).to.equal(nil)
			expect(snapshot(f, "Combat.LateHitStart." .. DEFAULT_WEAPON.Id)).to.equal(1)
		end)

		it("expires an attack through the scheduler", function()
			local attack = DEFAULT_WEAPON.Attacks[1]
			send(f, Actions.Attack, 1)
			expect(state_of(f).Active).to.be.ok()

			f.h.Clock:advance(attack.HitStartAt + attack.HitWindow + Config.Combat.TimingTolerance + 0.01)

			expect(state_of(f).Active).to.equal(nil)
		end)

		it("cancels the expiry callback when an attack is cleared", function()
			send(f, Actions.Attack, 1)
			local pending = f.h.Clock:pending()

			send(f, Actions.HitStop, 1)

			expect(state_of(f).Active).to.equal(nil)
			expect(f.h.Clock:pending()).to.equal(pending - 1)
		end)

		it("clears the attack when the attacker dies mid-window", function()
			local target, target_humanoid = make_target(f, Vector3.new(0, 0, -6))
			send(f, Actions.Attack, 1)
			start_hit(1)
			f.humanoid.Health = 0

			send(f, Actions.Hit, 1, target, f.hitpoint, Vector3.new(0, 0, -6))

			expect(state_of(f).Active).to.equal(nil)
			expect(target_humanoid.Health).to.equal(target_humanoid.MaxHealth)
		end)

		it("accepts a charge released long after its HitStart marker", function()
			local charge = DEFAULT_WEAPON.Charge
			send(f, Actions.Charge)
			f.h.Clock:advance(charge.MaxHoldTime - 1)

			start_hit("Charge")

			local active = state_of(f).Active
			expect(active).to.be.ok()
			expect(active.HitActive).to.equal(true)
			-- The charge's hit window is measured from its release.
			expect(active.HitExpiresAt).to.be.near(f.h.Clock.now() + charge.HitWindow + Config.Combat.TimingTolerance)
		end)

		it("rejects a charge released after MaxHoldTime", function()
			local charge = DEFAULT_WEAPON.Charge
			send(f, Actions.Charge)
			local active = state_of(f).Active
			-- Push the release past MaxHoldTime without letting expiry run.
			active.HitStartClosesAt = f.h.Clock.now() - 0.01
			expect(charge.MaxHoldTime > 0).to.equal(true)

			start_hit("Charge")

			expect(state_of(f).Active).to.equal(nil)
		end)

		it("drops hit packets with a malformed attack key", function()
			send(f, Actions.Attack, 1)
			start_hit(1)

			send(f, Actions.Hit, { 1 }, nil, nil, nil)

			expect(snapshot(f, "Combat.BadPayload." .. DEFAULT_WEAPON.Id)).to.equal(1)
			expect(state_of(f).Active.HitRequests).to.equal(0)
		end)
	end)
end
