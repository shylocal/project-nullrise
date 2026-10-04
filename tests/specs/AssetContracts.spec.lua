--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.shared.config)
local AssetContracts = require(ServerScriptService.server.AssetContracts)

local HITPOINT_NAME = Config.World.Names.HitpointAttachment

local function catalog(definitions: { [string]: any }): AssetContracts.CatalogLike
	local ids = {}
	for id in pairs(definitions) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return {
		Ids = function()
			return ids
		end,
		Get = function(id: any)
			return definitions[id]
		end,
	}
end

local function part(name: string, parent: Instance, hitpoint: boolean?): Part
	local instance = Instance.new("Part")
	instance.Name = name
	if hitpoint then
		local attachment = Instance.new("Attachment")
		attachment.Name = HITPOINT_NAME
		attachment.Parent = instance
	end
	instance.Parent = parent
	return instance
end

-- A two-part sword: Handle is wielded, Blade is the hitbox welded to it.
local function sword_definition(): any
	return {
		Model = "Sword",
		Wield = { Handle = "Right Arm" },
		Moves = { Light1 = { Hitbox = "Blade" }, Heavy = { Hitbox = "Blade" } },
	}
end

local function sword_models(): (Folder, Model, Part, Part)
	local models = Instance.new("Folder")
	local model = Instance.new("Model")
	model.Name = "Sword"
	model.Parent = models
	local handle = part("Handle", model)
	local blade = part("Blade", model, true)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = blade
	weld.Parent = handle
	return models, model, handle, blade
end

local function only(errors: { string }): string
	expect(#errors).to.equal(1)
	return errors[1]
end

return function()
	describe("AssetContracts.Verify", function()
		it("passes a template whose hitbox is welded to a wield part", function()
			local models = sword_models()
			expect(#AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)).to.equal(0)
			models:Destroy()
		end)

		it("reports a missing models folder", function()
			local message = only(AssetContracts.Verify(catalog({ Sword = sword_definition() }), nil))
			expect((message:find(Config.World.Folders.WeaponModels, 1, true))).to.be.ok()
		end)

		it("reports a missing template and a template without parts", function()
			local models = Instance.new("Folder")
			expect((only(AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)):find("^Sword: template 'Sword' is missing"))).to.be.ok()

			local empty = Instance.new("Model")
			empty.Name = "Sword"
			empty.Parent = models
			expect((only(AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)):find("must be a BasePart or a Model"))).to.be.ok()
			models:Destroy()
		end)

		it("reports an unresolved or non-part wield entry", function()
			local models, model = sword_models()
			local definition = sword_definition()
			definition.Wield.Grip = "Left Arm"
			expect((only(AssetContracts.Verify(catalog({ Sword = definition }), models)):find("^Sword: Wield%.Grip: "))).to.be.ok()

			local grip = Instance.new("Folder")
			grip.Name = "Grip"
			grip.Parent = model
			expect((only(AssetContracts.Verify(catalog({ Sword = definition }), models)):find("^Sword: Wield%.Grip: "))).to.be.ok()
			models:Destroy()
		end)

		it("reports a missing hitbox per move, in move-name order", function()
			local models = sword_models()
			local definition = sword_definition()
			definition.Moves.Light1.Hitbox = "Tip"
			definition.Moves.Heavy.Hitbox = "Pommel"
			local errors = AssetContracts.Verify(catalog({ Sword = definition }), models)
			expect(#errors).to.equal(2)
			expect((errors[1]:find("^Sword: Moves%.Heavy%.Hitbox: no BasePart named 'Pommel'"))).to.be.ok()
			expect((errors[2]:find("^Sword: Moves%.Light1%.Hitbox: no BasePart named 'Tip'"))).to.be.ok()
			models:Destroy()
		end)

		it("requires a hitpoint attachment anywhere under the hitbox", function()
			local models, _, _, blade = sword_models()
			local attachment = blade:FindFirstChild(HITPOINT_NAME) :: Instance
			local holder = Instance.new("Folder")
			holder.Parent = blade
			attachment.Parent = holder
			expect(#AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)).to.equal(0)

			attachment:Destroy()
			local errors = AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)
			expect(#errors).to.equal(2)
			expect((errors[1]:find("has no Attachment named '" .. HITPOINT_NAME .. "'", 1, true))).to.be.ok()
			models:Destroy()
		end)

		it("requires the hitbox to be connected to a wield part", function()
			local models, _, handle = sword_models()
			local weld = handle:FindFirstChildOfClass("WeldConstraint") :: WeldConstraint
			weld:Destroy()
			local definition = sword_definition()
			definition.Moves = { Light1 = { Hitbox = "Blade" } }
			expect((only(AssetContracts.Verify(catalog({ Sword = definition }), models)):find("neither a wield part nor welded"))).to.be.ok()
			models:Destroy()
		end)

		it("follows joints and rigid constraints through intermediate parts", function()
			local models, model, handle, blade = sword_models()
			local weld = handle:FindFirstChildOfClass("WeldConstraint") :: WeldConstraint
			weld:Destroy()
			local guard = part("Guard", model)

			local motor = Instance.new("Motor6D")
			motor.Part0 = handle
			motor.Part1 = guard
			motor.Parent = handle

			local a0 = Instance.new("Attachment")
			a0.Parent = guard
			local a1 = Instance.new("Attachment")
			a1.Parent = blade
			local rigid = Instance.new("RigidConstraint")
			rigid.Attachment0 = a0
			rigid.Attachment1 = a1
			rigid.Parent = guard

			expect(#AssetContracts.Verify(catalog({ Sword = sword_definition() }), models)).to.equal(0)
			models:Destroy()
		end)

		it("ignores joints that leave the template", function()
			local models, _, handle, blade = sword_models()
			local weld = handle:FindFirstChildOfClass("WeldConstraint") :: WeldConstraint
			weld:Destroy()
			local outside = Instance.new("Part")
			for _, other in ipairs({ handle, blade }) do
				local constraint = Instance.new("WeldConstraint")
				constraint.Part0 = other
				constraint.Part1 = outside
				constraint.Parent = other
			end
			local definition = sword_definition()
			definition.Moves = { Light1 = { Hitbox = "Blade" } }
			expect((only(AssetContracts.Verify(catalog({ Sword = definition }), models)):find("neither a wield part"))).to.be.ok()
			models:Destroy()
			outside:Destroy()
		end)

		it("accepts a wield part that is its own hitbox", function()
			local models = Instance.new("Folder")
			local fists = Instance.new("Model")
			fists.Name = "Fists"
			fists.Parent = models
			part("RightFist", fists, true)
			part("LeftFist", fists, true)
			local definition = {
				Model = "Fists",
				Wield = { RightFist = "Right Arm", LeftFist = "Left Arm" },
				Moves = { Light1 = { Hitbox = "RightFist" }, Light2 = { Hitbox = "LeftFist" } },
			}
			expect(#AssetContracts.Verify(catalog({ Fists = definition }), models)).to.equal(0)
			models:Destroy()
		end)
	end)

	describe("AssetContracts.Report", function()
		it("does nothing without errors", function()
			AssetContracts.Report({}, true)
			AssetContracts.Report({}, false)
		end)

		it("raises every error at once in Studio", function()
			local ok, message = pcall(function()
				AssetContracts.Report({ "A: one", "B: two" }, true)
			end)
			expect(ok).to.equal(false)
			expect((tostring(message):find("A: one\nB: two", 1, true))).to.be.ok()
		end)
	end)
end
