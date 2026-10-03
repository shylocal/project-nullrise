local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local CombatService = require(Services.CombatService)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)

local function make_character(created)
	local character = Instance.new("Model")
	character.Name = "CombatServiceSpecCharacter"
	character.Parent = Workspace
	table.insert(created, character)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	return character, humanoid
end

local function make_wielded(character)
	local wielded = Instance.new("Part")
	wielded.Name = "SpecWielded"
	wielded.Anchored = true
	wielded.Parent = character
	return wielded
end

local function make_fixture(player, character, active)
	local session = {
		Character = character,
	}
	local service = setmetatable({
		PlayerService = {
			Get = function(_, requested_player)
				if requested_player == player then
					return session
				end
				return nil
			end,
		},
		WeaponService = nil,
		ActiveAttacks = {
			[player] = active,
		},
	}, CombatService)

	return service, session
end

local function make_active(character, attack_key)
	local now = os.clock()
	return {
		AttackIndex = attack_key or 1,
		IsCharge = attack_key == "Charge",
		Character = character,
		Attack = {
			Damage = 10,
			Hitbox = "TestHitbox",
			HitWindow = 0.5,
		},
		Wielded = nil,
		HitActive = true,
		HitExpiresAt = now + 30,
		HitTargets = {},
		HitCount = 0,
		HitRequests = 0,
		StartedAt = now,
		HitStartOpensAt = now - 1,
		HitStartClosesAt = now + 30,
		ExpiresAt = now + 30,
	}
end

local function make_remote()
	local remote = {
		OnServerEvent = {},
		Sent = {},
	}

	function remote:FireClient(player, ...)
		table.insert(self.Sent, table.pack(player, ...))
	end

	return remote
end

-- A service wired through _start with fake signals so tests drive the real
-- remote dispatch. Returns the service, the OnServerEvent handler and the
-- player's session.
local function make_started_service(player, character, weapon, wielded)
	local connections = {}
	local remote = make_remote()
	local session = {
		Character = character,
	}
	local service = setmetatable({
		Trove = {
			Connect = function(_, signal, callback)
				connections[signal] = callback
			end,
		},
		Remote = remote,
		PlayerService = {
			PlayerAdded = {},
			PlayerRemoving = {},
			GetPlayers = function()
				return {}
			end,
			Get = function(_, requested_player)
				if requested_player == player then
					return session
				end
				return nil
			end,
		},
		WeaponService = {
			EquippedChanged = {},
			GetEquipped = function()
				return weapon
			end,
			GetWielded = function()
				return wielded
			end,
		},
		ActiveAttacks = {},
		NextAttack = {},
		NextAttackAt = {},
		RemoteAt = {},
		PlayerTroves = {},
	}, CombatService)

	service:_start()

	return service, connections[remote.OnServerEvent], session
end

return function()
	describe("CombatService active attack lifecycle", function()
		local created

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		it("clears an active hit window when the attacker dies", function()
			local player = {}
			local character, humanoid = make_character(created)
			local active = make_active(character)
			local service = make_fixture(player, character, active)
			humanoid.Health = 0

			service:_hit(player, active.AttackIndex, nil, nil, nil)

			expect(service.ActiveAttacks[player]).to.equal(nil)
			expect(next(active.HitTargets)).to.equal(nil)
		end)

		it("rejects an active attack after the player's character is replaced", function()
			local player = {}
			local old_character = make_character(created)
			local new_character = make_character(created)
			local active = make_active(old_character)
			active.HitActive = false
			local service, session = make_fixture(player, old_character, active)
			session.Character = new_character

			service:_hit_start(player, active.AttackIndex)

			expect(service.ActiveAttacks[player]).to.equal(nil)
			expect(active.HitActive).to.equal(false)
		end)

		it("clears an expired active hit window even before its timeout callback runs", function()
			local player = {}
			local character = make_character(created)
			local active = make_active(character)
			active.ExpiresAt = os.clock() - 1
			local service = make_fixture(player, character, active)

			service:_hit(player, active.AttackIndex, nil, nil, nil)

			expect(service.ActiveAttacks[player]).to.equal(nil)
		end)

		it("clears an attack when a hit arrives after its hit window", function()
			local player = {}
			local character = make_character(created)
			local active = make_active(character)
			active.HitExpiresAt = os.clock() - 0.01
			local service = make_fixture(player, character, active)

			service:_hit(player, active.AttackIndex, nil, nil, nil)

			expect(service.ActiveAttacks[player]).to.equal(nil)
		end)

		it("resets active attack sequencing without resetting timing when the equipped weapon changes", function()
			local player = {}
			local active = make_active(nil)
			active.HitTargets = {
				[{}] = true,
			}

			local remote_event = {}
			local player_added = {}
			local player_removing = {}
			local equipped_changed = {}
			local connections = {}
			local next_attack_at = os.clock() + 5
			local remote_at = {
				Attack = os.clock(),
			}
			local service = setmetatable({
				Trove = {
					Connect = function(_, signal, callback)
						connections[signal] = callback
					end,
				},
				Remote = {
					OnServerEvent = remote_event,
				},
				PlayerService = {
					PlayerAdded = player_added,
					PlayerRemoving = player_removing,
					GetPlayers = function()
						return {}
					end,
					Get = function()
						return nil
					end,
				},
				WeaponService = {
					EquippedChanged = equipped_changed,
				},
				ActiveAttacks = {
					[player] = active,
				},
				NextAttack = {
					[player] = 2,
				},
				NextAttackAt = {
					[player] = next_attack_at,
				},
				RemoteAt = {
					[player] = remote_at,
				},
				PlayerTroves = {},
			}, CombatService)

			service:_start()
			connections[equipped_changed](player, "Katana")

			expect(service.ActiveAttacks[player]).to.equal(nil)
			expect(next(active.HitTargets)).to.equal(nil)
			expect(service.NextAttack[player]).to.equal(1)
			expect(service.NextAttackAt[player]).to.equal(next_attack_at)
			expect(service.RemoteAt[player]).to.equal(remote_at)
		end)

		it("clears attack state and player cleanup ownership on removal", function()
			local player = {}
			local active = make_active(nil)
			active.HitTargets = {
				[{}] = true,
			}
			local player_trove = {
				Destroyed = false,
				Destroy = function(self)
					self.Destroyed = true
				end,
			}
			local service = setmetatable({
				ActiveAttacks = {
					[player] = active,
				},
				NextAttack = {
					[player] = 2,
				},
				NextAttackAt = {
					[player] = os.clock() + 5,
				},
				RemoteAt = {
					[player] = {
						Attack = os.clock(),
					},
				},
				PlayerTroves = {
					[player] = player_trove,
				},
			}, CombatService)

			service:_player_removing(player)

			expect(service.ActiveAttacks[player]).to.equal(nil)
			expect(next(active.HitTargets)).to.equal(nil)
			expect(service.NextAttack[player]).to.equal(nil)
			expect(service.NextAttackAt[player]).to.equal(nil)
			expect(service.RemoteAt[player]).to.equal(nil)
			expect(service.PlayerTroves[player]).to.equal(nil)
			expect(player_trove.Destroyed).to.equal(true)
		end)

		it("allows hit activation for a living current character before expiry", function()
			local player = {}
			local character = make_character(created)
			local active = make_active(character)
			active.HitActive = false
			active.HitExpiresAt = nil
			local wielded = make_wielded(character)
			active.Wielded = wielded
			local service = make_fixture(player, character, active)
			service.WeaponService = {
				GetWielded = function()
					return wielded
				end,
			}

			service:_hit_start(player, active.AttackIndex)

			expect(service.ActiveAttacks[player]).to.equal(active)
			expect(active.HitActive).to.equal(true)
			expect(active.HitExpiresAt).to.equal(active.ExpiresAt)
		end)
	end)

	describe("CombatService attack requests", function()
		local created
		local fists = Catalog.Get("Fists")

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		local function last_reply(service)
			return service.Remote.Sent[#service.Remote.Sent]
		end

		it("accepts an attack and replies with the next combo index", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))

			on_event(player, Protocol.Combat.Attack, 1)

			local reply = last_reply(service)
			expect(#service.Remote.Sent).to.equal(1)
			expect(reply[1]).to.equal(player)
			expect(reply[2]).to.equal(Protocol.Combat.AttackAccepted)
			expect(reply[3]).to.equal(1)
			expect(reply[4]).to.equal(2)
			expect(service.ActiveAttacks[player].AttackIndex).to.equal(1)
		end)

		it("rejects a rate-limited attack instead of dropping it", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))

			on_event(player, Protocol.Combat.Attack, 1)
			on_event(player, Protocol.Combat.Attack, 2)

			local reply = last_reply(service)
			expect(#service.Remote.Sent).to.equal(2)
			expect(reply[2]).to.equal(Protocol.Combat.AttackRejected)
			expect(reply[3]).to.equal(2)
			expect(reply[4]).to.equal(2)
		end)

		it("rejects a new attack before the previous attack's MinDuration", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))

			on_event(player, Protocol.Combat.Attack, 1)
			local first_active = service.ActiveAttacks[player]
			-- Bypass the packet rate limit so only MinDuration applies.
			service.RemoteAt[player] = nil
			on_event(player, Protocol.Combat.Attack, 2)

			expect(#service.Remote.Sent).to.equal(2)
			expect(last_reply(service)[2]).to.equal(Protocol.Combat.AttackRejected)
			expect(service.ActiveAttacks[player]).to.equal(first_active)
		end)

		it("accepts the next attack once MinDuration has elapsed", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))

			on_event(player, Protocol.Combat.Attack, 1)
			service.RemoteAt[player] = nil
			service.NextAttackAt[player] = os.clock() - 0.01
			on_event(player, Protocol.Combat.Attack, 2)

			local reply = last_reply(service)
			expect(reply[2]).to.equal(Protocol.Combat.AttackAccepted)
			expect(reply[3]).to.equal(2)
			expect(reply[4]).to.equal(1)
		end)

		it("rejects when the attack context is missing", function()
			local player = {}
			local character = make_character(created)
			local service, on_event, session = make_started_service(player, character, fists, make_wielded(character))
			session.Character = nil

			on_event(player, Protocol.Combat.Attack, 1)

			local reply = last_reply(service)
			expect(#service.Remote.Sent).to.equal(1)
			expect(reply[2]).to.equal(Protocol.Combat.AttackRejected)
			expect(reply[3]).to.equal(1)
		end)

		it("rejects malformed attack indices without echoing them", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))

			on_event(player, Protocol.Combat.Attack, 1.5)

			local reply = last_reply(service)
			expect(#service.Remote.Sent).to.equal(1)
			expect(reply[2]).to.equal(Protocol.Combat.AttackRejected)
			expect(reply[3]).to.equal(nil)
		end)

		it("does not throttle hit packets that arrive in the same frame", function()
			local player = {}
			local character = make_character(created)
			local service, on_event = make_started_service(player, character, fists, make_wielded(character))
			local hit_targets = {}
			service._hit = function(_, _, _, hit_character)
				table.insert(hit_targets, hit_character)
			end

			local first_target = {}
			local second_target = {}
			on_event(player, Protocol.Combat.Hit, 1, first_target)
			on_event(player, Protocol.Combat.Hit, 1, second_target)

			expect(#hit_targets).to.equal(2)
			expect(hit_targets[1]).to.equal(first_target)
			expect(hit_targets[2]).to.equal(second_target)
		end)
	end)

	describe("CombatService definition-driven timing", function()
		local created
		local fists = Catalog.Get("Fists")

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		local function make_timing_fixture()
			local player = {}
			local character = make_character(created)
			local wielded = make_wielded(character)
			local service = make_fixture(player, character, nil)
			service.WeaponService = {
				GetWielded = function()
					return wielded
				end,
			}
			return service, player, character, wielded
		end

		it("ignores a HitStart before the definition's HitStartAt", function()
			local service, player, character, wielded = make_timing_fixture()
			local attack = table.clone(fists.Attacks[1])
			attack.HitStartAt = 5
			local active = service:_create_active(player, 1, attack, wielded, character, os.clock())

			service:_hit_start(player, 1)

			expect(service.ActiveAttacks[player]).to.equal(active)
			expect(active.HitActive).to.equal(false)
		end)

		it("clears a light attack whose hit window has passed", function()
			local service, player, character, wielded = make_timing_fixture()
			local attack = fists.Attacks[1]
			local started_at = os.clock() - (attack.HitStartAt + attack.HitWindow + 1)
			service:_create_active(player, 1, attack, wielded, character, started_at)

			service:_hit_start(player, 1)

			expect(service.ActiveAttacks[player]).to.equal(nil)
		end)

		it("accepts a charge released long after its HitStart marker", function()
			local service, player, character, wielded = make_timing_fixture()
			local charge = fists.Charge
			-- Held for most of MaxHoldTime, well past HitStartAt.
			local started_at = os.clock() - (charge.MaxHoldTime - 1)
			local active = service:_create_active(player, "Charge", charge, wielded, character, started_at)

			service:_hit_start(player, "Charge")

			expect(service.ActiveAttacks[player]).to.equal(active)
			expect(active.HitActive).to.equal(true)
			-- The charge's hit window is measured from its release.
			expect(active.HitExpiresAt > os.clock() + charge.HitWindow - 0.5).to.equal(true)
		end)

		it("rejects a charge released after MaxHoldTime", function()
			local service, player, character, wielded = make_timing_fixture()
			local charge = fists.Charge
			local started_at = os.clock() - (charge.MaxHoldTime + 1)
			service:_create_active(player, "Charge", charge, wielded, character, started_at)

			service:_hit_start(player, "Charge")

			expect(service.ActiveAttacks[player]).to.equal(nil)
		end)
	end)
end
