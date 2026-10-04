--!strict
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.shared.config)
local WeaponAttachment = require(ServerScriptService.server.services.WeaponAttachment)

local HITPOINT_TAG = Config.World.Tags.Hitpoint
local HITPOINT_NAME = Config.World.Names.HitpointAttachment

local function create_instance(class_name: string, name: string, parent: Instance?, created: { Instance }): any
	local instance = Instance.new(class_name)
	instance.Name = name
	instance.Parent = parent
	table.insert(created, instance)
	return instance
end

return function()
	describe("WeaponAttachment rig support", function()
		local created: { Instance }

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for index = #created, 1, -1 do
				created[index]:Destroy()
			end
		end)

		it("accepts R6 humanoid rigs", function()
			local character = create_instance("Model", "R6Character", Workspace, created)
			local humanoid = create_instance("Humanoid", "Humanoid", character, created)
			humanoid.RigType = Enum.HumanoidRigType.R6

			local supported = WeaponAttachment.IsSupportedRig(character)
			expect(supported).to.equal(true)
		end)

		it("rejects R15 rigs and characters without a Humanoid", function()
			local r15 = create_instance("Model", "R15Character", Workspace, created)
			local humanoid = create_instance("Humanoid", "Humanoid", r15, created)
			humanoid.RigType = Enum.HumanoidRigType.R15

			local supported, reason = WeaponAttachment.IsSupportedRig(r15)
			expect(supported).to.equal(false)
			expect(typeof(reason)).to.equal("string")

			local empty = create_instance("Model", "EmptyCharacter", Workspace, created)
			expect((WeaponAttachment.IsSupportedRig(empty))).to.equal(false)
			expect((WeaponAttachment.IsSupportedRig(nil))).to.equal(false)
		end)
	end)

	describe("WeaponAttachment model preparation", function()
		local created: { Instance }

		beforeEach(function()
			created = {}
		end)

		afterEach(function()
			for index = #created, 1, -1 do
				created[index]:Destroy()
			end
		end)

		it("prepares, welds, and tags a valid weapon clone", function()
			local character = create_instance("Model", "WeaponAttachmentCharacter", Workspace, created)
			local arm = create_instance("Part", "Right Arm", character, created)
			local source = create_instance("Model", "WeaponAttachmentTemplate", Workspace, created)
			local handle = create_instance("Part", "Handle", source, created)
			handle.Anchored = true
			handle.CanCollide = true
			handle.Massless = false
			create_instance("Attachment", HITPOINT_NAME, handle, created)

			local clone = WeaponAttachment.Attach(source, {
				Handle = "Right Arm",
			}, character)
			expect(clone ~= nil).to.equal(true)

			if clone then
				local found = clone:FindFirstChild("Handle", true)
				expect(found ~= nil and found:IsA("BasePart")).to.equal(true)
				local cloned_handle = found :: BasePart
				local motor = cloned_handle:FindFirstChildOfClass("Motor6D")
				local hitpoint = cloned_handle:FindFirstChild(HITPOINT_NAME)

				expect(cloned_handle.Anchored).to.equal(false)
				expect(cloned_handle.CanCollide).to.equal(false)
				expect(cloned_handle.CanQuery).to.equal(false)
				expect(cloned_handle.Massless).to.equal(true)
				expect(motor ~= nil).to.equal(true)
				if motor then
					expect(motor.Part0).to.equal(arm)
					expect(motor.Part1).to.equal(cloned_handle)
				end
				expect(hitpoint ~= nil).to.equal(true)
				if hitpoint then
					expect(CollectionService:HasTag(hitpoint, HITPOINT_TAG)).to.equal(true)
				end
			end
		end)

		it("rejects a model without a BasePart and removes its clone", function()
			local character = create_instance("Model", "WeaponAttachmentCharacter", Workspace, created)
			local source = create_instance("Model", "EmptyWeaponTemplate", Workspace, created)

			local clone = WeaponAttachment.Attach(source, {}, character)

			expect(clone).to.equal(nil)
			expect(#character:GetChildren()).to.equal(0)
		end)

		it("skips malformed wield entries without breaking valid bindings", function()
			local character = create_instance("Model", "WeaponAttachmentCharacter", Workspace, created)
			create_instance("Part", "Right Arm", character, created)
			local source = create_instance("Model", "MixedWeaponTemplate", Workspace, created)
			create_instance("Part", "Good", source, created)
			create_instance("Folder", "Invalid", source, created)

			local clone = WeaponAttachment.Attach(source, {
				Good = "Right Arm",
				Invalid = "Right Arm",
				Missing = "Right Arm",
				BadTarget = 1,
				[1] = "Right Arm",
			}, character)
			expect(clone ~= nil).to.equal(true)

			if clone then
				local cloned_good = clone:FindFirstChild("Good", true)
				local good_motor = cloned_good and cloned_good:FindFirstChildOfClass("Motor6D")
				local invalid = clone:FindFirstChild("Invalid", true)

				expect(good_motor ~= nil).to.equal(true)
				if good_motor then
					expect(good_motor.Part1).to.equal(cloned_good)
				end
				expect(invalid ~= nil and invalid:FindFirstChildOfClass("Motor6D") ~= nil).to.equal(false)
			end
		end)
	end)
end
