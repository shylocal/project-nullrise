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

		it("fires AttackRejected with an optional key and next index", function()
			local client, remote = make_client()
			local rejected = record(client.AttackRejected)

			remote:Inject("AttackRejected", nil, 1)
			remote:Inject("AttackRejected", 2, 1)
			remote:Inject("AttackRejected", "Charge", nil)
			remote:Inject("AttackRejected", {}, 1)
			remote:Inject("AttackRejected", 1, "x")

			expect(#rejected).to.equal(3)
			expect(rejected[1][1]).to.equal(nil)
			expect(rejected[1][2]).to.equal(1)
			expect(rejected[2][1]).to.equal(2)
			expect(rejected[3][1]).to.equal("Charge")
			client:Destroy()
		end)

		it("fires HitConfirmed for a model target and drops other targets", function()
			local client, remote = make_client()
			local confirmed = record(client.HitConfirmed)
			local target = Instance.new("Model")

			remote:Inject("HitConfirmed", 1, target)
			remote:Inject("HitConfirmed", "Charge", target)
			remote:Inject("HitConfirmed", 1, Instance.new("Part"))
			remote:Inject("HitConfirmed", "Light", target)

			expect(#confirmed).to.equal(2)
			expect(confirmed[1][2]).to.equal(target)
			expect(confirmed[2][1]).to.equal("Charge")
			client:Destroy()
			target:Destroy()
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
