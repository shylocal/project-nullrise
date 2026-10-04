--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local WeaponController = require(StarterPlayer.StarterPlayerScripts.client.controllers.WeaponController)

local function make_weapon_model(name: string, part_name: string): (Model, Part)
	local model = Instance.new("Model")
	model.Name = name
	local holder = Instance.new("Folder")
	holder.Parent = model
	local part = Instance.new("Part")
	part.Name = part_name
	part.Parent = holder
	return model, part
end

return function()
	describe("WeaponController", function()
		it("requires a character", function()
			expect(function()
				-- Deliberately missing its dependency.
				WeaponController.new({} :: any)
			end).to.throw()
		end)

		it("equips only catalog weapons", function()
			local character = Instance.new("Model")
			local controller = WeaponController.new({ character = character })

			expect(controller:EquipById(Catalog.DefaultId)).to.equal(true)
			expect(controller.Equipped).to.equal(Catalog.Get(Catalog.DefaultId))
			expect(controller:EquipById("NotAWeapon")).to.equal(false)
			expect(controller:EquipById(nil :: any)).to.equal(false)
			expect(controller.Equipped).to.equal(Catalog.Get(Catalog.DefaultId))

			controller:Destroy()
			character:Destroy()
		end)

		it("resolves and caches wielded parts of the equipped model", function()
			local character = Instance.new("Model")
			local controller = WeaponController.new({ character = character })
			controller:EquipById("Katana")
			local weapon = assert(controller.Equipped, "Katana must equip")

			expect(controller:GetWielded("Handle")).to.equal(nil)

			local model, handle = make_weapon_model(weapon.Model, "Handle")
			model.Parent = character

			expect(controller:GetWielded("Handle")).to.equal(handle)
			expect(controller.CachedModel).to.equal(model)
			expect(controller.WieldCache.Handle).to.equal(handle)
			expect(controller:GetWielded("Handle")).to.equal(handle)

			controller:Destroy()
			character:Destroy()
		end)

		it("invalidates the cache when the model leaves the character", function()
			local character = Instance.new("Model")
			local controller = WeaponController.new({ character = character })
			controller:EquipById("Katana")
			local weapon = assert(controller.Equipped, "Katana must equip")

			local old_model, old_handle = make_weapon_model(weapon.Model, "Handle")
			old_model.Parent = character
			expect(controller:GetWielded("Handle")).to.equal(old_handle)

			old_model.Parent = nil
			expect(controller:GetWielded("Handle")).to.equal(nil)

			local new_model, new_handle = make_weapon_model(weapon.Model, "Handle")
			new_model.Parent = character
			expect(controller:GetWielded("Handle")).to.equal(new_handle)

			controller:Destroy()
			old_model:Destroy()
			character:Destroy()
		end)

		it("invalidates the cache on Equip", function()
			local character = Instance.new("Model")
			local controller = WeaponController.new({ character = character })
			controller:EquipById("Katana")

			local model = make_weapon_model(assert(controller.Equipped, "Katana must equip").Model, "Handle")
			model.Parent = character
			controller:GetWielded("Handle")
			expect(controller.CachedModel).to.equal(model)

			controller:EquipById(Catalog.DefaultId)
			expect(controller.CachedModel).to.equal(nil)
			expect((next(controller.WieldCache))).to.equal(nil)

			controller:Destroy()
			character:Destroy()
		end)
	end)
end
