--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local Config = require(ReplicatedStorage.shared.config)

local UiContracts = require(StarterPlayer.StarterPlayerScripts.client.UiContracts)

local WEAPON_ID = Config.World.Attributes.WeaponId

local function ui_with_menu(): (Folder, ScreenGui)
	local folder = Instance.new("Folder")
	local menu = Instance.new("ScreenGui")
	menu.Name = "WeaponMenu"
	menu.Parent = folder
	return folder, menu
end

local function button(parent: Instance, name: string, weapon_id: any): TextButton
	local instance = Instance.new("TextButton")
	instance.Name = name
	if weapon_id ~= nil then
		instance:SetAttribute(WEAPON_ID, weapon_id)
	end
	instance.Parent = parent
	return instance
end

return function()
	describe("UiContracts.Verify", function()
		it("treats missing templates as optional", function()
			expect(#UiContracts.Verify(Catalog, nil)).to.equal(0)
			local folder = Instance.new("Folder")
			expect(#UiContracts.Verify(Catalog, folder)).to.equal(0)
			folder:Destroy()
		end)

		it("passes buttons that name catalog weapons and ignores other buttons", function()
			local folder, menu = ui_with_menu()
			local frame = Instance.new("Frame")
			frame.Parent = menu
			for _, id in ipairs(Catalog.Ids()) do
				button(frame, id, id)
			end
			button(menu, "Close", nil)
			local label = Instance.new("TextLabel")
			label:SetAttribute(WEAPON_ID, "NotAWeapon")
			label.Parent = menu
			expect(#UiContracts.Verify(Catalog, folder)).to.equal(0)
			folder:Destroy()
		end)

		it("reports buttons whose WeaponId is not a catalog id", function()
			local folder, menu = ui_with_menu()
			local frame = Instance.new("Frame")
			frame.Name = "List"
			frame.Parent = menu
			button(frame, "Spear", "Spear")
			button(menu, "Number", 3)
			local errors = UiContracts.Verify(Catalog, folder)
			expect(#errors).to.equal(2)
			expect(errors[1]).to.equal("WeaponMenu.List.Spear: " .. WEAPON_ID .. " 'Spear' is not a Catalog weapon id")
			expect(errors[2]).to.equal("WeaponMenu.Number: " .. WEAPON_ID .. " '3' is not a Catalog weapon id")
			folder:Destroy()
		end)
	end)

	describe("UiContracts.Report", function()
		it("raises every error at once in Studio", function()
			UiContracts.Report({}, true)
			local ok, message = pcall(function()
				UiContracts.Report({ "one", "two" }, true)
			end)
			expect(ok).to.equal(false)
			expect((tostring(message):find("one\ntwo", 1, true))).to.be.ok()
		end)
	end)
end
