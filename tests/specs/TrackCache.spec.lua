local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Support = script.Parent.Parent.support
local FakeAnimationTrack = require(Support.FakeAnimationTrack)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local TrackCache = require(StarterPlayer.StarterPlayerScripts.client.controllers.AnimationController.TrackCache)

local function def(id, priority, looped)
	return { Id = id, Priority = priority, Looped = looped }
end

return function()
	describe("TrackCache", function()
		it("creates one Animation instance per id", function()
			local a = TrackCache.animation("rbxassetid://1")
			local b = TrackCache.animation("rbxassetid://1")
			expect(a).to.equal(b)
			expect(a.AnimationId).to.equal("rbxassetid://1")
		end)

		it("loads each role once across weapon swaps A -> B -> A", function()
			local animator = FakeAnimationTrack.animator()
			local cache = TrackCache.new(animator)

			local idle_a = def("rbxassetid://101", Enum.AnimationPriority.Idle, true)
			local idle_b = def("rbxassetid://202", Enum.AnimationPriority.Idle, true)

			local first = cache:Get("Idle", idle_a)
			cache:Get("Idle", idle_b)
			local again = cache:Get("Idle", idle_a)

			expect(animator.Loads).to.equal(2)
			expect(again).to.equal(first)
			cache:Destroy()
		end)

		it("keys by role so roles sharing an id get separate tracks", function()
			local animator = FakeAnimationTrack.animator()
			local cache = TrackCache.new(animator)
			local shared = def("rbxassetid://303", Enum.AnimationPriority.Idle, true)

			local idle = cache:Get("Idle", shared)
			local sprint = cache:Get("Sprint", shared)

			expect(idle).never.to.equal(sprint)
			expect(animator.Loads).to.equal(2)
			cache:Destroy()
		end)

		it("applies Priority and Looped on first load", function()
			local animator = FakeAnimationTrack.animator()
			local cache = TrackCache.new(animator)
			local track = cache:Get("Attack1", def("rbxassetid://404", Enum.AnimationPriority.Action, false))

			expect(track.Priority).to.equal(Enum.AnimationPriority.Action)
			expect(track.Looped).to.equal(false)
			cache:Destroy()
		end)

		it("stops and destroys its tracks on Destroy", function()
			local animator = FakeAnimationTrack.animator()
			local cache = TrackCache.new(animator)
			local track = cache:Get("Idle", def("rbxassetid://505", Enum.AnimationPriority.Idle, true))
			track:Play()

			cache:Destroy()
			cache:Destroy()

			expect(track.IsPlaying).to.equal(false)
			expect(track.Destroyed).to.equal(true)
		end)

		it("collects every catalog animation once by id", function()
			local defs = TrackCache.collect_catalog()
			local ids = {}
			for _, animation in ipairs(defs) do
				expect(ids[animation.Id]).to.equal(nil)
				ids[animation.Id] = true
			end

			for _, weapon in ipairs(Catalog.All()) do
				for _, animation in pairs(weapon.Animations) do
					expect(ids[animation.Id]).to.equal(true)
				end
				for _, attack in ipairs(weapon.Attacks) do
					expect(ids[attack.Animation.Id]).to.equal(true)
				end
			end
		end)

		it("returns a destroyable preload handle", function()
			local handle = TrackCache.preload({})
			expect(typeof(handle.Destroy)).to.equal("function")
			handle.Destroy()
			handle.Destroy()
		end)
	end)
end
