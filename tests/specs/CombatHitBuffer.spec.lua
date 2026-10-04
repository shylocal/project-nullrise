--!strict
-- Hits that arrive while an early HitStart is armed (before HitStartOpensAt)
-- are buffered on the active move and validated when the window opens.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Signal = require(ReplicatedStorage.packages.Signal)
local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local Services = ServerScriptService.server.services
local CombatService = require(Services.CombatService)
local DamageService = require(Services.DamageService)
local PositionHistory = require(Services.PositionHistory)
local ServerHarness = require(TestService.support.ServerHarness)

local Actions = Protocol.Combat
local MAX_BUFFERED = Config.Combat.MaxHitRequestsPerAttack
-- Far enough out that the HitStart is always early and the window is still
-- shut while the specs send their hits.
local LATE_HIT_START_AT = 5

local DEFAULT_WEAPON = Catalog.Get(Catalog.DefaultId) :: any
local LIGHT1 = DEFAULT_WEAPON.Moves.Light1.Id

type Get = (name: string) -> any

type Fixture = {
	h: any,
	remote: any,
	weapons: any,
	player: any,
	character: Model,
	hitpoint: Attachment,
	weapon: any,
}

-- A copy of the default weapon whose Light1 opens its hit window late.
local function late_weapon(): any
	local copy = table.clone(DEFAULT_WEAPON)
	copy.Moves = {}
	for name, move in DEFAULT_WEAPON.Moves do
		copy.Moves[name] = table.clone(move)
	end
	copy.Moves.Light1.HitStartAt = LATE_HIT_START_AT
	return copy
end

-- Attacker at the origin facing -Z, wielding a part 3 studs ahead that
-- carries a tagged hitpoint.
local function setup(): Fixture
	local h = ServerHarness.new()
	local remote = h.Remotes.Combat
	local weapon = late_weapon()
	local weapons = {
		EquippedChanged = Signal.new(),
		Weapon = weapon,
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
	h.Runtime:Add("PositionHistory", function(get: Get)
		return PositionHistory.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			step = Signal.new(),
			capacity = Config.Combat.LagCompensation.HistoryCapacity,
		})
	end)
	h.Runtime:Add("DamageService", function(get: Get)
		return DamageService.new({
			players = get("PlayerService"),
			scheduler = h.Clock:scheduler(),
			config = Config.Combat.Damage,
			tags = Config.World.Tags,
		})
	end)
	h.Runtime:Add("CombatService", function(get: Get)
		return CombatService.new({
			players = get("PlayerService"),
			weapons = get("Weapons"),
			remote = remote,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
			scheduler = h.Clock:scheduler(),
			damage = get("DamageService"),
			history = get("PositionHistory"),
		})
	end)
	h:Start()

	local character = h:Character({
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
		player = player,
		character = character,
		hitpoint = hitpoint,
		weapon = weapon,
	}
end

local function send(f: Fixture, ...: any)
	f.remote:Inject(f.player, ...)
end

local function active_of(f: Fixture): any
	local session = f.h:Get("PlayerService"):Get(f.player)
	return session:Get(f.h:Get("CombatService")).Active
end

local function snapshot(f: Fixture, reason: string): number?
	return f.h:Get("Telemetry"):Snapshot()[("Combat.%s.%s"):format(reason, f.weapon.Id)]
end

local function confirmations(f: Fixture): number
	local count = 0
	for _, packed in f.remote.Sent do
		if packed[2] == Actions.HitConfirmed then
			count += 1
		end
	end
	return count
end

-- Starts Light1 and arms its HitStart (it always arrives early here).
local function arm(f: Fixture): any
	send(f, Actions.Attack, LIGHT1)
	f.h.Clock:advance(0.0625)
	send(f, Actions.HitStart, LIGHT1)
	local active = active_of(f)
	assert(active and active.PendingHitStart, "HitStart was not armed")
	return active
end

local function open_window(f: Fixture, active: any)
	f.h.Clock:advance(active.HitStartOpensAt - f.h.Clock.now())
end

return function()
	describe("CombatService hits during an armed HitStart", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		it("buffers a hit and applies it when the window opens", function()
			local target, humanoid = f.h:Character({ Name = "Target", CFrame = CFrame.new(0, 0, -6) })
			local active = arm(f)

			send(f, Actions.Hit, LIGHT1, target, f.hitpoint, Vector3.new(0, 0, -6))

			expect(#active.PendingHits).to.equal(1)
			expect(humanoid.Health).to.equal(humanoid.MaxHealth)
			expect(snapshot(f, "NotActive")).to.equal(nil)

			open_window(f, active)

			expect(active.HitActive).to.equal(true)
			expect(#active.PendingHits).to.equal(0)
			expect(active.HitRequests).to.equal(1)
			expect(humanoid.Health).to.equal(humanoid.MaxHealth - f.weapon.Moves.Light1.Damage)
			expect(confirmations(f)).to.equal(1)
		end)

		it("does not buffer a malformed hit", function()
			local target = f.h:Character({ Name = "Target", CFrame = CFrame.new(0, 0, -6) })
			local active = arm(f)

			send(f, Actions.Hit, LIGHT1, target, nil, Vector3.new(0, 0, -6))

			expect(#active.PendingHits).to.equal(0)
			expect(snapshot(f, "BadPayload")).to.equal(1)
		end)

		it("drops the buffer when the move is cleared", function()
			local target, humanoid = f.h:Character({ Name = "Target", CFrame = CFrame.new(0, 0, -6) })
			local active = arm(f)
			send(f, Actions.Hit, LIGHT1, target, f.hitpoint, Vector3.new(0, 0, -6))

			send(f, Actions.HitStop, LIGHT1)

			expect(active_of(f)).to.equal(nil)
			expect(#active.PendingHits).to.equal(0)

			f.h.Clock:advance(LATE_HIT_START_AT + 1)

			expect(humanoid.Health).to.equal(humanoid.MaxHealth)
			expect(confirmations(f)).to.equal(0)
		end)

		it("drops the buffer when the attacker's wielded part changed", function()
			local target, humanoid = f.h:Character({ Name = "Target", CFrame = CFrame.new(0, 0, -6) })
			local active = arm(f)
			send(f, Actions.Hit, LIGHT1, target, f.hitpoint, Vector3.new(0, 0, -6))

			local replacement = Instance.new("Part")
			replacement.Parent = f.character
			f.weapons.Wielded = replacement
			open_window(f, active)

			expect(active_of(f)).to.equal(nil)
			expect(#active.PendingHits).to.equal(0)
			expect(humanoid.Health).to.equal(humanoid.MaxHealth)
			expect(snapshot(f, "WieldMismatch")).to.equal(1)
		end)

		it("keeps one entry per target and at most MaxHitRequestsPerAttack", function()
			local active = arm(f)
			-- Payload-valid targets; they fail validation later (not in Workspace).
			local targets: { Model } = {}
			for index = 1, MAX_BUFFERED + 1 do
				local target = Instance.new("Model")
				target.Name = "BufferTarget" .. index
				table.insert(targets, target)
				send(f, Actions.Hit, LIGHT1, target, f.hitpoint, Vector3.new(0, 0, -6))
			end
			send(f, Actions.Hit, LIGHT1, targets[1], f.hitpoint, Vector3.new(0, 0, -6))

			expect(#active.PendingHits).to.equal(MAX_BUFFERED)
			expect(active.PendingHits[1].Target).to.equal(targets[1])
			expect(snapshot(f, "RejectLimit")).to.equal(1)
			expect(snapshot(f, "Duplicate")).to.equal(1)

			open_window(f, active)

			-- Every buffered hit went through normal validation, in order.
			expect(#active.PendingHits).to.equal(0)
			expect(active.HitRequests).to.equal(MAX_BUFFERED)
			expect(snapshot(f, "TargetInvalid")).to.equal(MAX_BUFFERED)

			for _, target in targets do
				target:Destroy()
			end
		end)
	end)
end
