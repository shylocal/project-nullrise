--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Support = script.Parent.Parent.support
local FakeClock = require(Support.FakeClock)
local FakeRemote = require(Support.FakeRemote)
local FakeAnimationTrack = require(Support.FakeAnimationTrack)

local Signal = require(ReplicatedStorage.packages.Signal)
local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

local Client = StarterPlayer.StarterPlayerScripts.client
local Controllers = Client.controllers
local CombatController = require(Controllers.CombatController)
local Hitbox = require(Controllers.CombatController.Hitbox)
local WeaponController = require(Controllers.WeaponController)
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)
local CombatClient = require(Client.session.CombatClient)

local function default_weapon(): any
	return assert(Catalog.Get(Catalog.DefaultId), "default weapon must exist")
end

local LIGHT1 = assert(Catalog.MoveId(Catalog.DefaultId, "Light1"))
local LIGHT2 = assert(Catalog.MoveId(Catalog.DefaultId, "Light2"))
local HEAVY = assert(Catalog.MoveId(Catalog.DefaultId, "Heavy"))

local function message(action: string, move_id: number): string
	return action .. ":" .. tostring(move_id)
end

-- AnimationController stand-in exposing the surface CombatController uses.
local function make_animation()
	local animation = {
		-- One track per default-weapon move name.
		Tracks = {
			Light1 = FakeAnimationTrack.new(),
			Light2 = FakeAnimationTrack.new(),
			Heavy = FakeAnimationTrack.new(),
		},
		Current = nil,
		StopCount = 0,
	}

	local function claim(track)
		if animation.Current and animation.Current ~= track then
			animation.Current:Stop(0)
		end
		animation.Current = track
		track.TimePosition = 0
		track:AdjustSpeed(1)
		return track
	end

	animation.Combat = {
		BeginMove = function(_, name)
			local track = animation.Tracks[name]
			return track and claim(track)
		end,
		Play = function(_, track, transition_time)
			track:Play(transition_time)
		end,
		Pause = function(_, track)
			if animation.Current == track then
				track:AdjustSpeed(0)
			end
		end,
		Resume = function(_, track)
			if animation.Current == track then
				track:AdjustSpeed(1)
			end
		end,
	}

	function animation.StopAction(_self)
		animation.StopCount += 1
		local track = animation.Current
		animation.Current = nil
		if track then
			track:Stop(0)
		end
	end

	return animation
end

local function make_harness(weapon_id: string?)
	local clock = FakeClock.new(0)
	local character = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	local weapon = WeaponController.new({ character = character })
	assert(weapon:EquipById(weapon_id or Catalog.DefaultId), "harness weapon must be equippable")

	local remote = FakeRemote.client()
	local combat = CombatClient.new({ remote = remote, fx_remote = FakeRemote.client() })
	local state = CharacterState.new({ policy = Policy })
	local input = { ActionBegan = Signal.new(), ActionEnded = Signal.new() }
	local animation = make_animation()

	local controller = CombatController.new({
		weapon = weapon,
		-- The fake's methods are untyped closures.
		animation = animation :: any,
		state = state,
		input = input,
		-- A class instance (metatable type) does not match the structural
		-- CombatLike in the analyzer; at runtime it has every member.
		combat = combat :: any,
		scheduler = clock:scheduler(),
	})

	local harness = {
		clock = clock,
		character = character,
		humanoid = humanoid,
		weapon = weapon,
		remote = remote,
		combat = combat,
		state = state,
		input = input,
		animation = animation,
		controller = controller,
	}

	function harness.press()
		input.ActionBegan:Fire("Primary")
	end

	function harness.release()
		input.ActionEnded:Fire("Primary")
	end

	function harness.tap()
		harness.press()
		harness.release()
	end

	-- Sent messages as "Action:key" strings.
	function harness.sent()
		local out = {}
		for _, packed in ipairs(remote.Sent) do
			table.insert(out, tostring(packed[1]) .. ":" .. tostring(packed[2]))
		end
		return out
	end

	function harness.destroy()
		controller:Destroy()
		state:Destroy()
		combat:Destroy()
		weapon:Destroy()
		character:Destroy()
	end

	return harness
end

local function contains(list, value)
	return table.find(list, value) ~= nil
end

return function()
	describe("CombatController construction", function()
		it("requires every dependency", function()
			expect(function()
				-- Deliberately missing every dependency.
				CombatController.new({} :: any)
			end).to.throw()
		end)
	end)

	describe("CombatController light attacks", function()
		it("sends a light attack on a tap and waits for the server", function()
			local h = make_harness()
			h.tap()

			expect(h.sent()[1]).to.equal(message("Attack", LIGHT1))
			expect(h.controller.PendingMoveId).to.equal(LIGHT1)
			expect(h.state:IsActive("Attack")).to.equal(true)
			expect(h.animation.Tracks.Light1.IsPlaying).to.equal(true)
			h.destroy()
		end)

		it("advances the combo only on AttackAccepted", function()
			local h = make_harness()
			h.tap()
			h.remote:Inject("AttackAccepted", LIGHT1, LIGHT2)

			expect(h.controller.PendingMoveId).to.equal(nil)
			expect(h.controller.NextComboMoveId).to.equal(LIGHT2)

			h.clock:advance(default_weapon().Moves.Light1.Cooldown)
			h.tap()
			expect(contains(h.sent(), message("Attack", LIGHT2))).to.equal(true)
			expect(h.animation.Tracks.Light2.IsPlaying).to.equal(true)
			h.destroy()
		end)

		it("resyncs the combo from AttackRejected", function()
			local h = make_harness()
			h.tap()
			h.remote:Inject("AttackRejected", LIGHT1, LIGHT2)

			expect(h.controller.PendingMoveId).to.equal(nil)
			expect(h.controller.NextComboMoveId).to.equal(LIGHT2)
			h.destroy()
		end)

		it("gives up on a pending attack after PendingAttackTimeout", function()
			local h = make_harness()
			h.tap()
			h.clock:advance(Config.Combat.PendingAttackTimeout - 0.05)
			expect(h.controller.PendingMoveId).to.equal(LIGHT1)

			h.clock:advance(0.1)
			expect(h.controller.PendingMoveId).to.equal(nil)

			-- A late reply for the abandoned request is ignored.
			h.remote:Inject("AttackAccepted", LIGHT1, LIGHT2)
			expect(h.controller.NextComboMoveId).to.equal(nil)
			h.destroy()
		end)

		it("ignores a reply naming a move that is not in the combo", function()
			local h = make_harness()
			h.tap()
			h.remote:Inject("AttackAccepted", LIGHT1, HEAVY)

			expect(h.controller.PendingMoveId).to.equal(nil)
			expect(h.controller.NextComboMoveId).to.equal(nil)
			h.destroy()
		end)

		it("drops a tap during the cooldown", function()
			local h = make_harness()
			h.tap()
			h.remote:Inject("AttackAccepted", LIGHT1, LIGHT2)
			h.clock:advance(0.1)
			h.tap()

			local attacks = 0
			for _, sent in ipairs(h.sent()) do
				if sent:sub(1, 7) == "Attack:" then
					attacks += 1
				end
			end
			expect(attacks).to.equal(1)
			h.destroy()
		end)

		it("sends HitStart and HitStop from the animation markers", function()
			local h = make_harness()
			h.tap()
			local track = h.animation.Tracks.Light1

			track:FireMarker("HitStart")
			track:FireMarker("HitStop")

			local sent = h.sent()
			expect(contains(sent, message("HitStart", LIGHT1))).to.equal(true)
			expect(contains(sent, message("HitStop", LIGHT1))).to.equal(true)
			h.destroy()
		end)

		it("finishes the attack and releases its lease when the track ends", function()
			local h = make_harness()
			h.tap()
			h.remote:Inject("AttackAccepted", LIGHT1, LIGHT2)
			h.remote:Clear()

			h.animation.Tracks.Light1:Finish()

			expect(h.sent()[1]).to.equal(message("HitStop", LIGHT1))
			expect(h.controller.CurrentMoveId).to.equal(nil)
			expect(h.state:IsActive("Attack")).to.equal(false)
			h.destroy()
		end)

		it("does not attack while a blocking activity is active", function()
			local h = make_harness()
			local lease = h.state:Acquire("spec", "Hang")
			h.tap()

			expect(#h.remote.Sent).to.equal(0)
			lease:Release()

			h.tap()
			expect(h.sent()[1]).to.equal(message("Attack", LIGHT1))
			h.destroy()
		end)

		it("does not attack while dead", function()
			local h = make_harness()
			h.humanoid.Health = 0
			h.tap()

			expect(#h.remote.Sent).to.equal(0)
			h.destroy()
		end)
	end)

	describe("CombatController charge", function()
		local function charge_def()
			return default_weapon().Moves.Heavy
		end

		it("turns a hold past HoldTime into a charge", function()
			local h = make_harness()
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime * 0.5)
			expect(#h.remote.Sent).to.equal(0)

			h.clock:advance(charge_def().Hold.HoldTime)
			expect(h.sent()[1]).to.equal(message("Attack", HEAVY))
			expect(h.controller.Charging).to.equal(true)
			-- Only combo moves wait for the server's reply.
			expect(h.controller.PendingMoveId).to.equal(nil)

			-- Releasing a charge never falls back to a light attack.
			h.release()
			expect(contains(h.sent(), message("Attack", LIGHT1))).to.equal(false)
			h.destroy()
		end)

		it("pauses on HitStart while held and starts the hit on release", function()
			local h = make_harness()
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime)
			local track = h.animation.Tracks.Heavy

			track:FireMarker("HitStart")
			expect(track.Speed).to.equal(0)
			expect(h.controller.ChargeReady).to.equal(true)
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(false)

			h.release()
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(true)
			expect(track.Speed).to.equal(1)
			expect(h.controller.Charging).to.equal(false)
			h.destroy()
		end)

		it("sends HitStart from the marker when released before it", function()
			local h = make_harness()
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime)
			h.release()
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(false)

			h.animation.Tracks.Heavy:FireMarker("HitStart")
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(true)
			h.destroy()
		end)

		it("auto-releases at MaxHoldTime", function()
			local h = make_harness()
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime)
			h.animation.Tracks.Heavy:FireMarker("HitStart")

			h.clock:advance(charge_def().Hold.MaxHoldTime - 0.05)
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(false)

			h.clock:advance(0.1)
			expect(contains(h.sent(), message("HitStart", HEAVY))).to.equal(true)
			expect(h.controller.Charging).to.equal(false)
			h.destroy()
		end)

		it("buffers a hold during the cooldown and charges when it ends", function()
			local h = make_harness()
			local cooldown = default_weapon().Moves.Light1.Cooldown
			h.tap()
			h.remote:Inject("AttackAccepted", LIGHT1, LIGHT2)

			h.clock:advance(0.1)
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime)
			expect(h.controller.BufferedMove).to.equal("Heavy")
			expect(contains(h.sent(), message("Attack", HEAVY))).to.equal(false)

			h.clock:advance(cooldown)
			expect(contains(h.sent(), message("Attack", HEAVY))).to.equal(true)
			expect(h.controller.BufferedMove).to.equal(nil)
			h.destroy()
		end)

		it("does not charge while a blocking activity is active", function()
			local h = make_harness()
			local lease = h.state:Acquire("spec", "Vault")
			h.press()
			h.clock:advance(charge_def().Hold.HoldTime)

			expect(contains(h.sent(), message("Attack", HEAVY))).to.equal(false)
			lease:Release()
			h.destroy()
		end)
	end)

	describe("CombatController reset", function()
		it("stops the current attack and releases its lease", function()
			local h = make_harness()
			h.tap()
			h.remote:Clear()

			h.controller:Reset()

			expect(h.sent()[1]).to.equal(message("HitStop", LIGHT1))
			expect(h.state:IsActive("Attack")).to.equal(false)
			expect(h.controller.PendingMoveId).to.equal(nil)
			expect(h.controller.NextComboMoveId).to.equal(nil)
			expect(h.animation.StopCount).to.equal(1)
			h.destroy()
		end)

		it("ignores scheduled callbacks from before the reset", function()
			local h = make_harness()
			h.press()
			h.controller:Reset()
			h.remote:Clear()

			h.clock:advance(Config.Combat.PendingAttackTimeout + 1)
			expect(#h.remote.Sent).to.equal(0)
			h.destroy()
		end)

		it("is idempotent on Destroy", function()
			local h = make_harness()
			h.controller:Destroy()
			h.controller:Destroy()
			h.state:Destroy()
			h.combat:Destroy()
			h.character:Destroy()
		end)
	end)

	describe("Hitbox target resolution", function()
		local function make_character(name)
			local model = Instance.new("Model")
			model.Name = name
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			local torso = Instance.new("Part")
			torso.Name = "Torso"
			torso.Parent = model
			return model, humanoid, torso
		end

		it("resolves a nested weapon part to the character holding it", function()
			local attacker = make_character("Attacker")
			local target = make_character("Target")
			local weapon = Instance.new("Model")
			weapon.Parent = target
			local inner = Instance.new("Model")
			inner.Parent = weapon
			local blade = Instance.new("Part")
			blade.Parent = inner

			expect(Hitbox.resolve_target(attacker, blade)).to.equal(target)

			attacker:Destroy()
			target:Destroy()
		end)

		it("ignores the owner, map containers and dead characters", function()
			local attacker, _, attacker_torso = make_character("Attacker")
			local target, target_humanoid, target_torso = make_character("Target")
			local map = Instance.new("Model")
			local wall = Instance.new("Part")
			wall.Parent = map

			expect(Hitbox.resolve_target(attacker, attacker_torso)).to.equal(nil)
			expect(Hitbox.resolve_target(attacker, wall)).to.equal(nil)
			expect(Hitbox.resolve_target(attacker, target_torso)).to.equal(target)

			target_humanoid.Health = 0
			expect(Hitbox.resolve_target(attacker, target_torso)).to.equal(nil)

			attacker:Destroy()
			target:Destroy()
			map:Destroy()
		end)
	end)
end
