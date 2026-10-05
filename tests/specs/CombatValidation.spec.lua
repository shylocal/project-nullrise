--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local RejectReason = require(ReplicatedStorage.shared.combat.RejectReason)
local CombatValidation = require(ServerScriptService.server.services.CombatValidation)

local function make_character(name: string, position: Vector3, created: { Instance }): Model
	local character = Instance.new("Model")
	character.Name = name
	character.Parent = Workspace
	table.insert(created, character)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 2)
	root.CFrame = CFrame.new(position)
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	return character
end

local function root_of(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

local function humanoid_of(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

local function make_attacker(created: { Instance }): Model
	local attacker = make_character("Attacker", Vector3.zero, created)
	root_of(attacker).CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
	return attacker
end

local function make_wielded(attacker: Model, position: Vector3): BasePart
	local wielded = Instance.new("Part")
	wielded.Name = "TestHitbox"
	wielded.Anchored = true
	wielded.CanCollide = false
	wielded.CFrame = CFrame.new(position)
	wielded.Parent = attacker
	return wielded
end

local function make_wall(position: Vector3, created: { Instance }): BasePart
	local wall = Instance.new("Part")
	wall.Name = "Wall"
	wall.Anchored = true
	wall.Size = Vector3.new(4, 6, 0.5)
	wall.CFrame = CFrame.new(position)
	wall.Parent = Workspace
	table.insert(created, wall)
	return wall
end

local function make_active(attacker: Model, wielded: BasePart): (any, Attachment)
	local segment = Instance.new("Attachment")
	segment.Name = Config.World.Names.HitpointAttachment
	segment.Parent = wielded
	CollectionService:AddTag(segment, Config.World.Tags.Hitpoint)

	local active = {
		Character = attacker,
		Wielded = wielded,
		Move = {
			Hitbox = "TestHitbox",
			Range = 8,
			HitPositionTolerance = 3,
		},
		ValidationRaycastParams = RaycastParams.new(),
	}

	return active, segment
end

local function validate(
	wielded: BasePart,
	active: any,
	target: any,
	segment: any,
	hit_position: any,
	opts: any?
): (Humanoid?, string?, boolean?)
	local weapon_service = {
		GetWielded = function()
			return wielded
		end,
	}
	return CombatValidation.ValidateHit(weapon_service, {}, active, target, segment, hit_position, opts)
end

-- PositionHistory stand-in: one recorded state per character, returned for
-- any time; Requested records the requested times.
local function fake_history(character: Model, root_cframe: CFrame, latest_time: number)
	local history = { Requested = {} :: { number } }
	local sample = {
		Time = latest_time,
		RootCFrame = root_cframe,
		BoxCFrame = root_cframe,
		BoxSize = Vector3.new(2, 2, 2),
	}
	function history.Latest(_self: any, model: Model)
		return if model == character then sample else nil
	end
	function history.Sample(self: any, model: Model, t: number)
		table.insert(self.Requested, t)
		return if model == character then sample else nil
	end
	return history
end

-- PositionHistory stand-in for an attacker that moved from `from` (at
-- latest_time - 0.1) to `to` (at latest_time). Sample returns the earlier
-- state for any time before latest_time.
local function moving_history(character: Model, from: Vector3, to: Vector3, latest_time: number)
	local history = {}
	local function sample(time: number, position: Vector3)
		local cframe = CFrame.new(position)
		return { Time = time, RootCFrame = cframe, BoxCFrame = cframe, BoxSize = Vector3.new(2, 2, 2) }
	end
	local latest = sample(latest_time, to)
	local earlier = sample(latest_time - 0.1, from)
	function history.Latest(_self: any, model: Model)
		return if model == character then latest else nil
	end
	function history.Sample(_self: any, model: Model, t: number)
		return if model ~= character then nil elseif t >= latest_time then latest else earlier
	end
	return history
end

local function reason_of(...: any): any
	local _, reason = ...
	return reason
end

return function()
	describe("CombatValidation hit boundary", function()
		local created: { Instance }

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for _, instance in ipairs(created) do
				instance:Destroy()
			end
		end)

		it("rejects missing hitpoint arguments instead of skipping spatial validation", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			expect(reason_of(validate(wielded, active, target, nil, Vector3.new(0, 0, -6)))).to.equal(RejectReason.BadPayload)
			expect(reason_of(validate(wielded, active, target, segment, nil))).to.equal(RejectReason.BadPayload)
			expect(reason_of(validate(wielded, active, "Target", segment, Vector3.zero))).to.equal(RejectReason.BadPayload)
			expect(reason_of(validate(wielded, active, target, segment, Vector3.new(0 / 0, 0, 0)))).to.equal(RejectReason.BadPayload)
		end)

		it("accepts a hit with valid segment, position, range, facing, and line of sight", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(humanoid_of(target))
			expect(reason).to.equal(nil)
		end)

		it("rejects self hits and targets outside Workspace", function()
			local attacker = make_attacker(created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local outside = make_character("Outside", Vector3.new(0, 0, -6), created)
			outside.Parent = nil

			expect(reason_of(validate(wielded, active, attacker, segment, Vector3.new(0, 0, -1)))).to.equal(RejectReason.TargetInvalid)
			expect(reason_of(validate(wielded, active, outside, segment, Vector3.new(0, 0, -6)))).to.equal(RejectReason.TargetInvalid)
		end)

		it("rejects a model nested inside a character instead of the character", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local held = Instance.new("Model")
			held.Name = "HeldWeapon"
			held.Parent = target
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, held, segment, Vector3.new(0, 0, -6))

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.TargetInvalid)
		end)

		it("rejects dead targets", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local humanoid = humanoid_of(target)
			assert(humanoid, "target has no humanoid")
			humanoid.Health = 0

			expect(reason_of(validate(wielded, active, target, segment, Vector3.new(0, 0, -6)))).to.equal(RejectReason.TargetInvalid)
		end)

		it("rejects a hitpoint that is not on the wielded part or not tagged", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local other = make_wielded(attacker, Vector3.new(0, 0, -3))
			local foreign = Instance.new("Attachment")
			foreign.Parent = other
			CollectionService:AddTag(foreign, Config.World.Tags.Hitpoint)
			expect(reason_of(validate(wielded, active, target, foreign, Vector3.new(0, 0, -6)))).to.equal(RejectReason.NoHitpoint)

			CollectionService:RemoveTag(segment, Config.World.Tags.Hitpoint)
			expect(reason_of(validate(wielded, active, target, segment, Vector3.new(0, 0, -6)))).to.equal(RejectReason.NoHitpoint)
		end)

		it("rejects when the wielded part changed", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local replacement = make_wielded(attacker, Vector3.new(0, 0, -3))

			local humanoid, reason = validate(replacement, active, target, segment, Vector3.new(0, 0, -6))

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.WieldMismatch)
		end)

		it("rejects targets behind the attacker", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, 6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, 3))
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.Facing)
		end)

		it("rejects an obstruction between attacker and target", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			make_wall(Vector3.new(0, 0, -4.5), created)
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.NoLOS)
		end)

		it("rejects a wall hit even when the hitpoint-to-impact segment is clear", function()
			-- The reported impact sits on the attacker's side of the wall, so a
			-- ray from the weapon hitpoint to the impact never touches the wall.
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			make_wall(Vector3.new(0, 0, -4.5), created)
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, target, segment, Vector3.new(0, 0, -4))

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.NoLOS)
		end)

		it("rejects an impact that is within weapon range of the target but not on its body", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -9), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			-- 1 stud from the hitpoint, 4 studs from the target's body.
			local humanoid, reason = validate(wielded, active, target, segment, Vector3.new(0, 0, -4))

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.OffBody)
		end)

		it("rejects an impact far from the weapon's hitpoint", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -1))
			local active, segment = make_active(attacker, wielded)

			-- On the target's body, but 5 studs from the hitpoint.
			local humanoid, reason = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.HitpointOffset)
		end)

		it("rejects a target outside weapon reach", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -20), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -19))
			local active, segment = make_active(attacker, wielded)

			local humanoid, reason = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.Reach)
		end)

		it("accepts a hit that only reaches the target's rewound position", function()
			local attacker = make_attacker(created)
			-- The target has moved out of reach; the attacker saw it at -6.
			local target = make_character("Target", Vector3.new(0, 0, -30), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local history = fake_history(target, CFrame.new(0, 0, -6), 50)

			local rejected_humanoid, reason = validate(wielded, active, target, segment, Vector3.new(0, 0, -6))
			expect(rejected_humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.Reach)

			local humanoid, no_reason, rewound =
				validate(wielded, active, target, segment, Vector3.new(0, 0, -6), { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(humanoid_of(target))
			expect(no_reason).to.equal(nil)
			expect(rewound).to.equal(true)
			expect(history.Requested[1]).to.be.near(50 - 0.2)
		end)

		it("accepts a running attacker's hit ahead of its server-side hitpoint", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -5.5), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -1))
			local active, segment = make_active(attacker, wielded)
			-- Sprinting toward the target at 24 studs/s; the client's weapon is
			-- 4 studs ahead of where the server holds it.
			local history = moving_history(attacker, Vector3.new(0, 0, 2.4), Vector3.zero, 50)
			local impact = Vector3.new(0, 0, -5)

			expect(reason_of(validate(wielded, active, target, segment, impact))).to.equal(RejectReason.HitpointOffset)

			local humanoid, reason =
				validate(wielded, active, target, segment, impact, { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(humanoid_of(target))
			expect(reason).to.equal(nil)
		end)

		it("gives a stationary attacker no extra hitpoint allowance", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -5.5), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -1))
			local active, segment = make_active(attacker, wielded)
			local history = moving_history(attacker, Vector3.zero, Vector3.zero, 50)

			local humanoid, reason =
				validate(wielded, active, target, segment, Vector3.new(0, 0, -5), { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.HitpointOffset)
		end)

		it("caps the attacker's lead at MaxAttackerSpeed", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -13.5), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -1))
			local active, segment = make_active(attacker, wielded)
			-- 400 studs/s observed; the lead is capped at MaxAttackerSpeed * Rewind.
			local history = moving_history(attacker, Vector3.new(0, 0, 40), Vector3.zero, 50)
			local rewind = 0.2
			local cap = Config.Combat.LagCompensation.MaxAttackerSpeed * rewind
			local impact = Vector3.new(0, 0, -1 - cap - 4)

			local humanoid, reason =
				validate(wielded, active, target, segment, impact, { History = history, Rewind = rewind })
			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.HitpointOffset)
		end)

		it("does not rewind a hit that passes against the current state", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local history = fake_history(target, CFrame.new(0, 0, -6), 50)

			local humanoid, _, rewound =
				validate(wielded, active, target, segment, root_of(target).Position, { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(humanoid_of(target))
			expect(rewound).to.equal(false)
			expect(#history.Requested).to.equal(0)
		end)

		it("still rejects a hit that fails against the rewound position", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -30), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)
			local history = fake_history(target, CFrame.new(0, 0, -25), 50)

			local humanoid, reason =
				validate(wielded, active, target, segment, Vector3.new(0, 0, -6), { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.Reach)
		end)

		it("checks line of sight to the rewound position", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -30), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			make_wall(Vector3.new(0, 0, -4.5), created)
			local active, segment = make_active(attacker, wielded)
			local history = fake_history(target, CFrame.new(0, 0, -6), 50)

			local humanoid, reason =
				validate(wielded, active, target, segment, Vector3.new(0, 0, -6), { History = history, Rewind = 0.2 })
			expect(humanoid).to.equal(nil)
			expect(reason).to.equal(RejectReason.NoLOS)
		end)

		it("does not treat non-collidable parts as cover", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local wall = make_wall(Vector3.new(0, 0, -4.5), created)
			wall.CanCollide = false
			local active, segment = make_active(attacker, wielded)

			local humanoid = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(humanoid_of(target))
		end)

		it("does not treat a bystander character as cover", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			make_character("Bystander", Vector3.new(0, 0, -4.5), created)
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local humanoid = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(humanoid_of(target))
		end)

		it("does not treat a bystander's nested weapon model as cover", function()
			local attacker = make_attacker(created)
			local target = make_character("Target", Vector3.new(0, 0, -6), created)
			local bystander = make_character("Bystander", Vector3.new(3, 0, -4.5), created)
			-- A held weapon Model inside the bystander, with a nested Model,
			-- crossing the line between attacker and target.
			local held = Instance.new("Model")
			held.Name = "HeldWeapon"
			held.Parent = bystander
			local inner = Instance.new("Model")
			inner.Name = "Blade"
			inner.Parent = held
			local blade = Instance.new("Part")
			blade.Anchored = true
			blade.Size = Vector3.new(4, 4, 0.5)
			blade.CFrame = CFrame.new(0, 0, -4.5)
			blade.Parent = inner
			local wielded = make_wielded(attacker, Vector3.new(0, 0, -3))
			local active, segment = make_active(attacker, wielded)

			local humanoid = validate(wielded, active, target, segment, root_of(target).Position)

			expect(humanoid).to.equal(humanoid_of(target))
		end)
	end)
end
