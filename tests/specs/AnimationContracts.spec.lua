--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestService = game:GetService("TestService")

local AnimationContracts = require(ReplicatedStorage.shared.weapons.AnimationContracts)
local AnimationManifest = require(ReplicatedStorage.shared.weapons.AnimationManifest)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local BakeAnimationManifest = require(TestService.tools.BakeAnimationManifest)

local LIGHT_ID = "rbxassetid://1"
local HEAVY_ID = "rbxassetid://2"

-- Authored-shape definition (MoveDefaults not merged, no Name/Id injected),
-- which is what the Catalog hands AnimationContracts.
local function definition(): any
	return {
		MoveDefaults = { HitWindow = 0.5 },
		Moves = {
			Light1 = {
				Kind = "Light",
				Animation = { Id = LIGHT_ID },
				MinDuration = 0.3,
				HitStartAt = 0.1,
			},
			Heavy = {
				Kind = "Charge",
				Animation = { Id = HEAVY_ID },
				MinDuration = 0.6,
				HitStartAt = 0.15,
			},
		},
	}
end

local function manifest(): any
	return {
		[LIGHT_ID] = { Length = 0.8, Markers = { HitStart = 0.1, HitStop = 0.6 } },
		[HEAVY_ID] = { Length = 1, Markers = { HitStart = 0.15, HitStop = 0.5 } },
	}
end

local function make_keyframe(sequence: KeyframeSequence, time: number, markers: { string }): Keyframe
	local keyframe = Instance.new("Keyframe")
	keyframe.Time = time
	for _, name in ipairs(markers) do
		local marker = Instance.new("KeyframeMarker")
		marker.Name = name
		keyframe:AddMarker(marker)
	end
	keyframe.Parent = sequence
	return keyframe
end

return function()
	describe("AnimationContracts.check", function()
		it("passes moves that match their baked animation", function()
			expect(#AnimationContracts.check(definition(), "W", manifest())).to.equal(0)
		end)

		it("skips moves whose animation is not in the manifest", function()
			expect(#AnimationContracts.check(definition(), "W", {})).to.equal(0)
		end)

		it("requires HitStartAt at or before the HitStart marker, within 1ms", function()
			local data = manifest()
			data[LIGHT_ID].Markers.HitStart = 0.0995
			expect(#AnimationContracts.check(definition(), "W", data)).to.equal(0)

			data[LIGHT_ID].Markers.HitStart = 0.05
			local errors = AnimationContracts.check(definition(), "W", data)
			expect(#errors).to.equal(1)
			expect((errors[1]:find("^W%.Moves%.Light1%.HitStartAt: "))).to.be.ok()
		end)

		it("requires a Light move's window to reach the HitStop marker, using MoveDefaults", function()
			local data = manifest()
			data[LIGHT_ID].Markers.HitStop = 0.61
			local errors = AnimationContracts.check(definition(), "W", data)
			expect(#errors).to.equal(1)
			expect((errors[1]:find("^W%.Moves%.Light1%.HitWindow: "))).to.be.ok()

			-- An authored HitWindow wins over MoveDefaults.
			local def = definition()
			def.Moves.Light1.HitWindow = 0.6
			expect(#AnimationContracts.check(def, "W", data)).to.equal(0)
		end)

		it("does not apply the HitStop rule to Charge moves", function()
			local data = manifest()
			data[HEAVY_ID].Markers.HitStop = 5
			expect(#AnimationContracts.check(definition(), "W", data)).to.equal(0)
		end)

		it("requires MinDuration within the animation length", function()
			local data = manifest()
			data[HEAVY_ID].Length = 0.5
			local errors = AnimationContracts.check(definition(), "W", data)
			expect(#errors).to.equal(1)
			expect((errors[1]:find("^W%.Moves%.Heavy%.MinDuration: "))).to.be.ok()
		end)

		it("requires a HitStart marker on Charge moves", function()
			local data = manifest()
			data[HEAVY_ID].Markers = {}
			local errors = AnimationContracts.check(definition(), "W", data)
			expect(#errors).to.equal(1)
			expect((errors[1]:find("^W%.Moves%.Heavy%.Animation: "))).to.be.ok()
		end)

		it("collects every violation in move-name order", function()
			local data = manifest()
			data[LIGHT_ID].Length = 0.1
			data[HEAVY_ID].Markers = {}
			local errors = AnimationContracts.check(definition(), "W", data)
			expect(#errors).to.equal(2)
			expect((errors[1]:find("^W%.Moves%.Heavy%."))).to.be.ok()
			expect((errors[2]:find("^W%.Moves%.Light1%."))).to.be.ok()
		end)

		it("ignores malformed definitions, which the Validator reports", function()
			expect(#AnimationContracts.check(nil, "W", manifest())).to.equal(0)
			expect(#AnimationContracts.check({ Moves = { Bad = 3, Light1 = { Animation = 5 } } }, "W", manifest())).to.equal(0)
		end)

		it("holds for every catalog weapon against the committed manifest", function()
			for _, id in ipairs(Catalog.Ids()) do
				local errors = AnimationContracts.check(Catalog.Get(id), id, AnimationManifest)
				if #errors > 0 then
					error(table.concat(errors, "\n"), 0)
				end
			end
		end)
	end)

	describe("BakeAnimationManifest", function()
		it("collects distinct role and move animation ids, sorted", function()
			local ids = BakeAnimationManifest.collect_ids({
				{
					Animations = { Idle = { Id = "b" }, Equip = { Id = "a" } },
					Moves = { Light1 = { Animation = { Id = "c" } }, Heavy = { Animation = { Id = "a" } } },
				},
				{ Animations = { Idle = { Id = "c" } } },
			})
			expect(table.concat(ids, ",")).to.equal("a,b,c")
		end)

		it("collects every catalog animation", function()
			local ids = BakeAnimationManifest.collect_ids(Catalog.All())
			expect(#ids > 0).to.equal(true)
			for _, definition_ in ipairs(Catalog.All()) do
				expect(table.find(ids, definition_.Animations.Idle.Id) ~= nil).to.equal(true)
			end
		end)

		it("bakes the length and the earliest HitStart/HitStop marker times", function()
			-- Keyframe.Time is single precision, so the times are exact binary fractions.
			local sequence = Instance.new("KeyframeSequence")
			make_keyframe(sequence, 0, {})
			make_keyframe(sequence, 0.25, { "HitStart" })
			make_keyframe(sequence, 0.5, { "HitStop", "Other" })
			make_keyframe(sequence, 0.625, { "HitStart" })
			make_keyframe(sequence, 0.75, {})

			local entry = BakeAnimationManifest.bake(sequence)
			expect(entry.Length).to.equal(0.75)
			expect(entry.Markers.HitStart).to.equal(0.25)
			expect(entry.Markers.HitStop).to.equal(0.5)
			expect(entry.Markers.Other).to.equal(nil)
			sequence:Destroy()
		end)

		it("renders a sorted manifest module", function()
			local source = BakeAnimationManifest.render({
				["rbxassetid://9"] = { Length = 1.5, Markers = {} },
				["rbxassetid://10"] = { Length = 0.5, Markers = { HitStop = 0.3, HitStart = 0.1 } },
			})
			expect((source:find("^%-%-!strict\n"))).to.be.ok()
			local first = source:find('["rbxassetid://10"] = { Length = 0.5, Markers = { HitStart = 0.1, HitStop = 0.3 } },', 1, true)
			local second = source:find('["rbxassetid://9"] = { Length = 1.5, Markers = {} },', 1, true)
			expect(first).to.be.ok()
			expect(second).to.be.ok()
			expect((first :: number) < (second :: number)).to.equal(true)
			expect((source:find("\n}\n$"))).to.be.ok()
		end)
	end)
end
