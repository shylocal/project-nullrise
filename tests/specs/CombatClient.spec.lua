local StarterPlayer = game:GetService("StarterPlayer")

local Support = script.Parent.Parent.support
local FakeRemote = require(Support.FakeRemote)
local CombatClient = require(StarterPlayer.StarterPlayerScripts.client.session.CombatClient)

local function make_client()
	local remote = FakeRemote.client()
	local fx_remote = FakeRemote.client()
	local client = CombatClient.new({ remote = remote, fx_remote = fx_remote })
	return client, remote, fx_remote
end

local function record(signal)
	local calls = {}
	signal:Connect(function(...)
		table.insert(calls, table.pack(...))
	end)
	return calls
end

return function()
	describe("CombatClient", function()
		it("requires both remotes", function()
			expect(function()
				CombatClient.new({ remote = FakeRemote.client() } :: any)
			end).to.throw()
		end)

		it("forwards Send to the Combat remote", function()
			local client, remote = make_client()
			client:Send("Attack", 1)

			expect(#remote.Sent).to.equal(1)
			expect(remote.Sent[1][1]).to.equal("Attack")
			expect(remote.Sent[1][2]).to.equal(1)
			client:Destroy()
		end)

		it("fires AttackAccepted only for integer payloads", function()
			local client, remote = make_client()
			local accepted = record(client.AttackAccepted)

			remote:Inject("AttackAccepted", 1, 2)
			remote:Inject("AttackAccepted", "1", 2)
			remote:Inject("AttackAccepted", 1, nil)
			remote:Inject("AttackAccepted", 1.5, 2)

			expect(#accepted).to.equal(1)
			expect(accepted[1][1]).to.equal(1)
			expect(accepted[1][2]).to.equal(2)
			client:Destroy()
		end)

		it("fires AttackRejected with an optional move id and next combo move id", function()
			local client, remote = make_client()
			local rejected = record(client.AttackRejected)

			remote:Inject("AttackRejected", nil, 1)
			remote:Inject("AttackRejected", 2, 1)
			remote:Inject("AttackRejected", 3, nil)
			remote:Inject("AttackRejected", "Charge", nil)
			remote:Inject("AttackRejected", {}, 1)
			remote:Inject("AttackRejected", 1, "x")

			expect(#rejected).to.equal(3)
			expect(rejected[1][1]).to.equal(nil)
			expect(rejected[1][2]).to.equal(1)
			expect(rejected[2][1]).to.equal(2)
			expect(rejected[3][1]).to.equal(3)
			expect(rejected[3][2]).to.equal(nil)
			client:Destroy()
		end)

		it("fires HitConfirmed for a move id and a model target and drops the rest", function()
			local client, remote = make_client()
			local confirmed = record(client.HitConfirmed)
			local target = Instance.new("Model")

			remote:Inject("HitConfirmed", 1, target)
			remote:Inject("HitConfirmed", "Charge", target)
			remote:Inject("HitConfirmed", 1, Instance.new("Part"))
			remote:Inject("HitConfirmed", 2.5, target)

			expect(#confirmed).to.equal(1)
			expect(confirmed[1][1]).to.equal(1)
			expect(confirmed[1][2]).to.equal(target)
			client:Destroy()
			target:Destroy()
		end)

		it("fires FxHit for well-formed CombatFx hits and drops malformed ones", function()
			local client, _, fx_remote = make_client()
			local hits = record(client.FxHit)
			local damaged = record(client.Damaged)
			local victim = Instance.new("Model")
			local source = Instance.new("Model")
			local position = Vector3.new(1, 2, 3)

			fx_remote:Inject("Hit", victim, source, "Fists", 2, position, 10)
			fx_remote:Inject("Hit", victim, nil, "Fists", 2, position, 10)
			fx_remote:Inject("Hit", Instance.new("Part"), source, "Fists", 2, position, 10)
			fx_remote:Inject("Hit", victim, source, 5, 2, position, 10)
			fx_remote:Inject("Hit", victim, source, "Fists", 1.5, position, 10)
			fx_remote:Inject("Hit", victim, source, "Fists", 2, Vector3.new(0 / 0, 0, 0), 10)
			fx_remote:Inject("Hit", victim, source, "Fists", 2, position, math.huge)
			fx_remote:Inject("Nope", victim, source, "Fists", 2, position, 10)

			expect(#hits).to.equal(2)
			expect(hits[1][1]).to.equal(victim)
			expect(hits[1][2]).to.equal(source)
			expect(hits[1][3]).to.equal("Fists")
			expect(hits[1][4]).to.equal(2)
			expect(hits[1][5]).to.equal(position)
			expect(hits[1][6]).to.equal(10)
			expect(hits[2][2]).to.equal(nil)
			-- The victim is not the local character (there is none in specs).
			expect(#damaged).to.equal(0)

			client:Destroy()
			fx_remote:Inject("Hit", victim, source, "Fists", 2, position, 10)
			expect(#hits).to.equal(2)
			victim:Destroy()
			source:Destroy()
		end)

		it("ignores unknown actions and stops listening after Destroy", function()
			local client, remote = make_client()
			local accepted = record(client.AttackAccepted)

			remote:Inject("Nope", 1, 2)
			client:Destroy()
			remote:Inject("AttackAccepted", 1, 2)
			client:Send("Attack", 1)

			expect(#accepted).to.equal(0)
			expect(#remote.Sent).to.equal(0)
		end)
	end)
end
