--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local InventoryService = require(ServerScriptService.server.services.InventoryService)
local WeaponService = require(ServerScriptService.server.services.WeaponService)
local ServerHarness = require(TestService.support.ServerHarness)

local DEFAULT_ID = Catalog.DefaultId

local function item_id(): string
	for _, id in Catalog.Ids() do
		if id ~= DEFAULT_ID then
			return id
		end
	end
	error("the catalog has no item weapon")
end

local ITEM = item_id()

-- One template per catalog weapon: a Model with a Part for every wield key
-- and every attack hitbox, each carrying a hitpoint attachment.
local function make_models(): Folder
	local folder = Instance.new("Folder")
	folder.Name = "SpecWeaponModels"

	for _, definition in Catalog.All() do
		local def = definition :: any
		local model = Instance.new("Model")
		model.Name = def.Model
		model.Parent = folder

		local names: { [string]: boolean } = {}
		for wield_name in def.Wield do
			names[wield_name] = true
		end
		for _, attack in def.Attacks do
			names[attack.Hitbox] = true
		end

		for name in names do
			local part = Instance.new("Part")
			part.Name = name
			part.Size = Vector3.new(1, 1, 1)
			part.Parent = model
			local hitpoint = Instance.new("Attachment")
			hitpoint.Name = Config.World.Names.HitpointAttachment
			hitpoint.Parent = part
		end
	end

	return folder
end

-- Adds a limb for every character part any weapon wields onto.
local function add_limbs(character: Model)
	for _, definition in Catalog.All() do
		for _, limb_name in (definition :: any).Wield do
			if not character:FindFirstChild(limb_name) then
				local limb = Instance.new("Part")
				limb.Name = limb_name
				limb.Anchored = true
				limb.Size = Vector3.new(1, 2, 1)
				limb.Parent = character
			end
		end
	end
end

type Fixture = {
	h: any,
	models: Folder,
	weapons: any,
	inventory: any,
}

local function setup(): Fixture
	local h = ServerHarness.new()
	local models = make_models()
	h:Track(models)

	h.Runtime:Add("InventoryService", function(get)
		return InventoryService.new({
			players = get("PlayerService"),
			remote = h.Remotes.Inventory,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)
	h.Runtime:Add("WeaponService", function(get)
		return WeaponService.new({
			players = get("PlayerService"),
			inventory = get("InventoryService"),
			remote = h.Remotes.Weapon,
			weapon_models = models,
		})
	end)
	h:Start()

	return {
		h = h,
		models = models,
		weapons = h:Get("WeaponService"),
		inventory = h:Get("InventoryService"),
	}
end

local function spawn_character(f: Fixture, player: any, rig: Enum.HumanoidRigType?): Model
	local character = f.h:Character({ RigType = rig })
	add_limbs(character)
	player:SetCharacter(character)
	return character
end

local function wield_name(weapon_id: string): string
	for name in (Catalog.Get(weapon_id) :: any).Wield do
		return name
	end
	error("weapon has no wield parts")
end

return function()
	describe("WeaponService", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		it("starts every player on the default weapon without announcing it", function()
			local player = f.h.Players:Add()

			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(DEFAULT_ID))
			expect(#f.h.Remotes.Weapon.Sent).to.equal(0)
		end)

		it("attaches the equipped weapon to the character with query-free parts", function()
			local player = f.h.Players:Add()
			local character = spawn_character(f, player)

			local part = f.weapons:GetWielded(player, wield_name(DEFAULT_ID))
			expect(part).to.be.ok()
			expect(part:IsDescendantOf(character)).to.equal(true)
			expect(part.CanQuery).to.equal(false)
			expect(part.CanCollide).to.equal(false)
		end)

		it("swaps the attached model and announces the equip", function()
			local player = f.h.Players:Add()
			local character = spawn_character(f, player)
			local old_part = f.weapons:GetWielded(player, wield_name(DEFAULT_ID))

			local changed = nil
			f.weapons.EquippedChanged:Connect(function(_player, weapon)
				changed = weapon
			end)

			expect(f.weapons:Equip(player, ITEM)).to.equal(true)

			expect(changed).to.equal(Catalog.Get(ITEM))
			expect(old_part.Parent).to.equal(nil)
			local new_part = f.weapons:GetWielded(player, wield_name(ITEM))
			expect(new_part).to.be.ok()
			expect(new_part:IsDescendantOf(character)).to.equal(true)

			local packet = f.h.Remotes.Weapon.Sent[#f.h.Remotes.Weapon.Sent]
			expect(packet[1]).to.equal(player)
			expect(packet[2]).to.equal(Protocol.Weapon.Equipped)
			expect(packet[3]).to.equal(ITEM)

			-- Equipping the same weapon again is a no-op.
			expect(f.weapons:Equip(player, ITEM)).to.equal(true)
			expect(f.weapons:GetWielded(player, wield_name(ITEM))).to.equal(new_part)
		end)

		it("follows the inventory selection", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)

			f.inventory:SelectItem(player, ITEM)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(ITEM))

			f.inventory:SelectItem(player, DEFAULT_ID)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(DEFAULT_ID))
		end)

		it("re-attaches the equipped weapon on respawn and drops the old model", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)
			f.weapons:Equip(player, ITEM)
			local old_part = f.weapons:GetWielded(player, wield_name(ITEM))

			local second = spawn_character(f, player)

			expect(old_part.Parent).to.equal(nil)
			local part = f.weapons:GetWielded(player, wield_name(ITEM))
			expect(part).to.be.ok()
			expect(part:IsDescendantOf(second)).to.equal(true)
		end)

		it("refuses weapons whose template is missing", function()
			local player = f.h.Players:Add()
			local template = f.models:FindFirstChild((Catalog.Get(ITEM) :: any).Model)
			assert(template, "template missing")
			template.Parent = nil

			expect(f.weapons:Equip(player, ITEM)).to.equal(false)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(DEFAULT_ID))
			template:Destroy()
		end)

		it("refuses unknown and non-string weapon ids", function()
			local player = f.h.Players:Add()

			expect(f.weapons:Equip(player, "MissingWeapon")).to.equal(false)
			expect(f.weapons:Equip(player, 1)).to.equal(false)
			expect(f.weapons:Equip({}, ITEM)).to.equal(false)
		end)

		it("does not arm unsupported rigs", function()
			local player = f.h.Players:Add()
			spawn_character(f, player, Enum.HumanoidRigType.R15)

			expect(f.weapons:GetWielded(player, wield_name(DEFAULT_ID))).to.equal(nil)
		end)

		it("forgets the player and their models when they leave", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)
			local part = f.weapons:GetWielded(player, wield_name(DEFAULT_ID))

			f.h.Players:Remove(player)

			expect(f.weapons:GetEquipped(player)).to.equal(nil)
			expect(part.Parent).to.equal(nil)
		end)
	end)
end
