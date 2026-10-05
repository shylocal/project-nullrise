--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TestService = game:GetService("TestService")

local Config = require(ReplicatedStorage.shared.config)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
local DataSchema = require(ReplicatedStorage.shared.data.Schema)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local PlayerDataService = require(ServerScriptService.server.services.PlayerDataService)
local InventoryService = require(ServerScriptService.server.services.InventoryService)
local WeaponService = require(ServerScriptService.server.services.WeaponService)
local ServerHarness = require(TestService.support.ServerHarness)
local FakeProfileStore = require(TestService.support.FakeProfileStore)

local DEFAULT_ID = Catalog.DefaultId
local WINDOW = Config.Inventory.EquipCoalesceWindow

local function item_id(): string
	for _, id in Catalog.Ids() do
		if id ~= DEFAULT_ID then
			return id
		end
	end
	error("the catalog has no item weapon")
end

local ITEM = item_id()

-- Every hitbox part name a definition's moves use.
local function hitbox_names(def: Catalog.WeaponDefinition, names: { [string]: boolean })
	for _, move in pairs(def.Moves) do
		names[move.Hitbox] = true
	end
end

-- One template per catalog weapon: a Model with a Part for every wield key
-- and every hitbox, each carrying a hitpoint attachment.
local function make_models(): Folder
	local folder = Instance.new("Folder")
	folder.Name = "SpecWeaponModels"

	for _, definition in Catalog.All() do
		local model = Instance.new("Model")
		model.Name = definition.Model
		model.Parent = folder

		local names: { [string]: boolean } = {}
		for wield_name in definition.Wield do
			names[wield_name] = true
		end
		hitbox_names(definition, names)

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
		for _, limb_name in definition.Wield do
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
	local store = FakeProfileStore.new(DataSchema.Template())

	h.Runtime:Add("PlayerDataService", function(get: (string) -> any)
		return PlayerDataService.new({
			players = get("PlayerService"),
			store = store,
			is_studio = false,
			config = Config.Data,
			telemetry = get("Telemetry"),
		})
	end)
	h.Runtime:Add("InventoryService", function(get: (string) -> any)
		return InventoryService.new({
			players = get("PlayerService"),
			data = get("PlayerDataService"),
			remote = h.Remotes.Inventory,
			budget = get("RemoteBudget"),
			telemetry = get("Telemetry"),
		})
	end)
	h.Runtime:Add("WeaponService", function(get: (string) -> any)
		return WeaponService.new({
			players = get("PlayerService"),
			inventory = get("InventoryService"),
			remote = h.Remotes.Weapon,
			weapon_models = models,
			scheduler = h.Clock:scheduler(),
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

local function model_of(f: Fixture, player: any, weapon_id: string): Instance
	local part = f.weapons:GetWielded(player, wield_name(weapon_id))
	assert(part, "no wielded part")
	local model = part:FindFirstAncestorOfClass("Model")
	assert(model, "wielded part has no model")
	return model
end

return function()
	-- Defined inside the spec function so TestEZ's injected `expect` is in scope.
	local function announced(f: Fixture): { string }
		local ids = {}
		for _, packet in f.h.Remotes.Weapon.Sent do
			expect(packet[2]).to.equal(Protocol.Weapon.Equipped)
			table.insert(ids, packet[3])
		end
		return ids
	end

	describe("WeaponService", function()
		local f: Fixture

		beforeEach(function()
			f = setup()
		end)

		afterEach(function()
			f.h:Destroy()
		end)

		it("requires a scheduler", function()
			expect(function()
				-- Deliberately missing the scheduler.
				WeaponService.new({ players = {}, inventory = {}, remote = {} } :: any)
			end).to.throw()
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
			local old_model = model_of(f, player, DEFAULT_ID)

			local changed = nil
			f.weapons.EquippedChanged:Connect(function(_player, weapon)
				changed = weapon
			end)

			expect(f.weapons:Equip(player, ITEM)).to.equal(true)

			expect(changed).to.equal(Catalog.Get(ITEM))
			expect(old_model.Parent).to.equal(nil)
			local new_part = f.weapons:GetWielded(player, wield_name(ITEM))
			expect(new_part).to.be.ok()
			expect(new_part:IsDescendantOf(character)).to.equal(true)

			local packet = f.h.Remotes.Weapon.Sent[#f.h.Remotes.Weapon.Sent]
			expect(packet[1]).to.equal(player)
			expect(packet[3]).to.equal(ITEM)

			-- Equipping the same weapon again is a no-op.
			f.h.Clock:advance(WINDOW)
			expect(f.weapons:Equip(player, ITEM)).to.equal(true)
			expect(f.weapons:GetWielded(player, wield_name(ITEM))).to.equal(new_part)
			expect(#announced(f)).to.equal(1)
		end)

		it("re-equips by reparenting the cached model", function()
			local player = f.h.Players:Add()
			local character = spawn_character(f, player)
			local default_model = model_of(f, player, DEFAULT_ID)

			f.weapons:Equip(player, ITEM)
			local item_model = model_of(f, player, ITEM)
			f.h.Clock:advance(WINDOW)

			f.weapons:Equip(player, DEFAULT_ID)
			expect(default_model.Parent).to.equal(character)
			expect(model_of(f, player, DEFAULT_ID)).to.equal(default_model)
			expect(item_model.Parent).to.equal(nil)
			f.h.Clock:advance(WINDOW)

			f.weapons:Equip(player, ITEM)
			expect(model_of(f, player, ITEM)).to.equal(item_model)
			expect(item_model.Parent).to.equal(character)
		end)

		it("coalesces equips inside the window into the latest request", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)

			expect(f.weapons:Equip(player, ITEM)).to.equal(true)
			expect(f.weapons:Equip(player, DEFAULT_ID)).to.equal(true)
			expect(f.weapons:Equip(player, ITEM)).to.equal(true)
			expect(f.weapons:Equip(player, DEFAULT_ID)).to.equal(true)

			-- Leading edge only so far.
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(ITEM))
			expect(#announced(f)).to.equal(1)

			f.h.Clock:advance(WINDOW)
			local ids = announced(f)
			expect(#ids).to.equal(2)
			expect(ids[2]).to.equal(DEFAULT_ID)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(DEFAULT_ID))

			-- The trailing equip opened a new window.
			f.weapons:Equip(player, ITEM)
			expect(#announced(f)).to.equal(2)
			f.h.Clock:advance(WINDOW)
			expect(#announced(f)).to.equal(3)
		end)

		it("drops a trailing request that matches the equipped weapon", function()
			local player = f.h.Players:Add()

			f.weapons:Equip(player, ITEM)
			f.weapons:Equip(player, DEFAULT_ID)
			f.weapons:Equip(player, ITEM)
			f.h.Clock:advance(WINDOW)

			expect(#announced(f)).to.equal(1)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(ITEM))

			-- The window is closed again: the next request applies at once.
			f.weapons:Equip(player, DEFAULT_ID)
			expect(#announced(f)).to.equal(2)
		end)

		it("follows the inventory selection", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)
			local uid = f.inventory:Grant(player, (ItemCatalog.ForWeapon(ITEM) :: any).Id)

			f.inventory:SelectUid(player, uid)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(ITEM))
			f.h.Clock:advance(WINDOW)

			f.inventory:SelectSlot(player, 0)
			expect(f.weapons:GetEquipped(player)).to.equal(Catalog.Get(DEFAULT_ID))
		end)

		it("re-attaches the equipped weapon on respawn and drops the old models", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)
			local default_model = model_of(f, player, DEFAULT_ID)
			f.weapons:Equip(player, ITEM)
			local old_part = f.weapons:GetWielded(player, wield_name(ITEM))

			local second = spawn_character(f, player)

			expect(old_part.Parent).to.equal(nil)
			expect(default_model.Parent).to.equal(nil)
			local part = f.weapons:GetWielded(player, wield_name(ITEM))
			expect(part).to.be.ok()
			expect(part).never.to.equal(old_part)
			expect(part:IsDescendantOf(second)).to.equal(true)
		end)

		it("refuses weapons whose template is missing", function()
			local player = f.h.Players:Add()
			local template = f.models:FindFirstChild((Catalog.Get(ITEM) :: any).Model)
			assert(template, "template missing")
			template.Parent = nil

			expect(f.weapons:Equip(player, ITEM)).to.equal(false)
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

		it("forgets the player, their models and any pending equip when they leave", function()
			local player = f.h.Players:Add()
			spawn_character(f, player)
			local part = f.weapons:GetWielded(player, wield_name(DEFAULT_ID))
			f.weapons:Equip(player, ITEM)
			f.weapons:Equip(player, DEFAULT_ID)

			f.h.Players:Remove(player)
			f.h.Clock:advance(WINDOW)

			expect(f.weapons:GetEquipped(player)).to.equal(nil)
			expect(part.Parent).to.equal(nil)
			expect(#announced(f)).to.equal(1)
		end)
	end)
end
