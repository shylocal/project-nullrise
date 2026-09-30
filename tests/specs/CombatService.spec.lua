local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Services = ServerScriptService:WaitForChild("server"):WaitForChild("services")
local CombatService = require(Services.CombatService)

local function make_character(created)
	local character = Instance.new("Model")
	character.Name = "CombatServiceSpecCharacter"
	character.Parent = Workspace
	table.insert(created, character)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = character

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character

	return character, humanoid
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
	return {
		AttackIndex = attack_key or 1,
		Character = character,
		Attack = {
			Damage = 10,
			Hitbox = "TestHitbox",
		},
		Timing = {},
		Wielded = nil,
		HitActive = true,
		HitTargets = {},
		StartedAt = os.clock(),
		ExpiresAt = os.clock() + 30,
	}
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
			expect(active.HitActive).to.equal(true)
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

		it("allows hit activation for a living current character before expiry", function()
			local player = {}
			local character = make_character(created)
			local active = make_active(character)
			active.HitActive = false
			local wielded = Instance.new("Part")
			wielded.Name = "TestHitbox"
			wielded.Parent = character
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
		end)
	end)
end
