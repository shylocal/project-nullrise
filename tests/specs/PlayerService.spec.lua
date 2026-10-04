--!strict
local TestService = game:GetService("TestService")

local ServerHarness = require(TestService.support.ServerHarness)

type Hooks = {
	Added: ((session: any) -> ())?,
}

-- Adds a component that records every hook call as "<name>:<hook>".
local function add_component(h: any, log: { string }, name: string, hooks: Hooks?): any
	local options: Hooks = hooks or {}
	local component = {}

	function component.OnPlayerAdded(_self: any, session: any)
		table.insert(log, name .. ":added")
		if options.Added then
			options.Added(session)
		end
	end

	function component.OnCharacterAdded(_self: any, session: any, character: Model, trove: any)
		assert(trove ~= nil and trove == session.CharacterTrove, "OnCharacterAdded without the character trove")
		assert(session.Character == character, "OnCharacterAdded for a stale character")
		table.insert(log, name .. ":character")
	end

	function component.OnCharacterRemoving(_self: any, session: any, character: Model)
		assert(session.Character == character, "OnCharacterRemoving after the character was released")
		table.insert(log, name .. ":character_removing")
	end

	function component.OnPlayerRemoving(_self: any, _session: any)
		table.insert(log, name .. ":removing")
	end

	function component.Destroy(_self: any) end

	h.Runtime:Add(name, function(get: (string) -> any)
		get("PlayerService"):Register(component, name)
		return component
	end)

	return component
end

local function joined(log: { string }): string
	return table.concat(log, ",")
end

return function()
	describe("PlayerService", function()
		local h: any

		beforeEach(function()
			h = ServerHarness.new()
		end)

		afterEach(function()
			h:Destroy()
		end)

		it("runs OnPlayerAdded in order, then Ready, then the current character", function()
			local log = {}
			add_component(h, log, "A")
			add_component(h, log, "B")
			h:Start()
			local service = h:Get("PlayerService")

			local ready_count = 0
			service.PlayerReady:Connect(function()
				ready_count += 1
			end)

			local player = h.Players:Add()
			local character = h:Character()
			expect(joined(log)).to.equal("A:added,B:added")
			expect(ready_count).to.equal(1)
			expect(service:GetReady(player)).to.equal(service:Get(player))
			expect(service:Get(player).Phase).to.equal("Ready")

			player:SetCharacter(character)
			expect(joined(log)).to.equal("A:added,B:added,A:character,B:character")
		end)

		it("dispatches an existing character when the session becomes Ready", function()
			local log = {}
			add_component(h, log, "A")
			add_component(h, log, "B")

			-- Joined before Start, with a character already spawned.
			local player = h.Players:Add()
			player.Character = h:Character()

			h:Start()

			expect(joined(log)).to.equal("A:added,B:added,A:character,B:character")
		end)

		it("dispatches character removal in reverse order before releasing the trove", function()
			local log = {}
			add_component(h, log, "A")
			add_component(h, log, "B")
			h:Start()
			local service = h:Get("PlayerService")

			local player = h.Players:Add()
			local first = h:Character()
			player:SetCharacter(first)
			local session = service:Get(player)
			local first_trove = session.CharacterTrove
			local released = false
			first_trove:Add(function()
				released = true
			end)
			table.clear(log)

			local second = h:Character()
			player:SetCharacter(second)

			expect(joined(log)).to.equal("B:character_removing,A:character_removing,A:character,B:character")
			expect(released).to.equal(true)
			expect(session.Character).to.equal(second)
			expect(session.CharacterTrove ~= first_trove).to.equal(true)
		end)

		it("releases a character that is destroyed without CharacterRemoving", function()
			local log = {}
			add_component(h, log, "A")
			h:Start()
			local service = h:Get("PlayerService")

			local player = h.Players:Add()
			local character = h:Character()
			player:SetCharacter(character)
			table.clear(log)

			character:Destroy()
			-- Destroying may be deferred under SignalBehavior.Deferred.
			task.wait()

			expect(joined(log)).to.equal("A:character_removing")
			expect(service:Get(player).Character).to.equal(nil)
		end)

		it("leaves in reverse order and destroys session state", function()
			local log = {}
			local destroyed = 0
			add_component(h, log, "A", {
				Added = function(session)
					session:Set("A", {
						Destroy = function()
							destroyed += 1
						end,
					})
				end,
			})
			add_component(h, log, "B")
			h:Start()
			local service = h:Get("PlayerService")

			local removing_phase
			service.PlayerRemoving:Connect(function(_player, session)
				removing_phase = session.Phase
			end)

			local player = h.Players:Add()
			player:SetCharacter(h:Character())
			table.clear(log)

			h.Players:Remove(player)

			expect(removing_phase).to.equal("Leaving")
			expect(joined(log)).to.equal("B:character_removing,A:character_removing,B:removing,A:removing")
			expect(destroyed).to.equal(1)
			expect(service:Get(player)).to.equal(nil)
		end)

		it("isolates a failing OnPlayerAdded and counts it", function()
			local log = {}
			add_component(h, log, "A", {
				Added = function()
					error("load failed", 0)
				end,
			})
			add_component(h, log, "B")
			h:Start()
			local service = h:Get("PlayerService")
			local telemetry = h:Get("Telemetry")

			local player = h.Players:Add()
			expect(joined(log)).to.equal("A:added,B:added")
			expect(service:GetReady(player)).to.be.ok()
			expect(telemetry:Snapshot()["Lifecycle.ComponentFailed.A"]).to.equal(1)

			player:SetCharacter(h:Character())
			table.clear(log)
			h.Players:Remove(player)

			-- The failed component gets no character or removal hooks.
			expect(joined(log)).to.equal("B:character_removing,B:removing")
		end)

		it("stops joining when the player leaves during a yielding OnPlayerAdded", function()
			local log = {}
			local thread: thread? = nil
			add_component(h, log, "A")
			add_component(h, log, "B", {
				Added = function()
					thread = coroutine.running()
					coroutine.yield()
				end,
			})
			add_component(h, log, "C")
			h:Start()
			local service = h:Get("PlayerService")

			local ready = false
			service.PlayerReady:Connect(function()
				ready = true
			end)

			local player = h.Players:Add()
			local session = service:Get(player)
			expect(session.Phase).to.equal("Loading")
			expect(service:GetReady(player)).to.equal(nil)

			h.Players:Remove(player)
			expect(joined(log)).to.equal("A:added,B:added,A:removing")

			-- The loader resumes after the player left; nothing else runs.
			assert(thread, "B did not yield")
			task.spawn(thread)

			expect(joined(log)).to.equal("A:added,B:added,A:removing")
			expect(ready).to.equal(false)
			expect(session.Phase).to.equal("Leaving")
		end)

		it("destroys state set on a session that already ended", function()
			h:Start()
			local service = h:Get("PlayerService")
			local player = h.Players:Add()
			local session = service:Get(player)
			h.Players:Remove(player)

			local destroyed = false
			session:Set("late", {
				Destroy = function()
					destroyed = true
				end,
			})

			expect(destroyed).to.equal(true)
			expect(session:Get("late")).to.equal(nil)
		end)

		it("replaces and clears session state, destroying the previous value", function()
			h:Start()
			local service = h:Get("PlayerService")
			local session = service:Get(h.Players:Add())

			local destroyed = {}
			local function state(name: string)
				return {
					Destroy = function()
						table.insert(destroyed, name)
					end,
				}
			end

			local first = state("first")
			session:Set("key", first)
			session:Set("key", first)
			session:Set("key", state("second"))
			session:Clear("key")

			expect(table.concat(destroyed, ",")).to.equal("first,second")
			expect(session:Get("key")).to.equal(nil)
		end)

		it("processes players already in the server on Start", function()
			local log = {}
			add_component(h, log, "A")
			local player = h.Players:Add()

			h:Start()

			expect(joined(log)).to.equal("A:added")
			expect(h:Get("PlayerService"):GetReady(player)).to.be.ok()
		end)

		it("rejects duplicate registrations", function()
			add_component(h, {}, "A")
			h.Runtime:Add("Duplicate", function(get: (string) -> any): any
				get("PlayerService"):Register({}, "A")
				return { Destroy = function() end }
			end)

			expect(function()
				h:Start()
			end).to.throw()
		end)

		it("rejects registration after Start", function()
			add_component(h, {}, "A")
			h:Start()
			local service = h:Get("PlayerService")

			expect(function()
				service:Register({}, "Late")
			end).to.throw()
		end)

		it("runs leave for every session on Destroy", function()
			local log = {}
			add_component(h, log, "A")
			h:Start()
			local service = h:Get("PlayerService")
			local first = h.Players:Add()
			local second = h.Players:Add()
			table.clear(log)

			service:Destroy()

			expect(joined(log)).to.equal("A:removing,A:removing")
			expect(service:Get(first)).to.equal(nil)
			expect(service:Get(second)).to.equal(nil)
		end)
	end)
end
