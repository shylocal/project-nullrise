--!strict
-- Listener for a server-to-client remote. Clients can still fire it, and an
-- event with no OnServerEvent listener is queued by the engine, which warns
-- into the server log. The sink drains those events and charges each one to
-- the sender's RemoteBudget as an unknown action, so it costs global budget
-- and is counted in telemetry without the client's text.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local RemoteBudget = require(script.Parent.RemoteBudget)

-- Specs pass a FakeRemote.
export type RemoteLike = RemoteEvent | UnreliableRemoteEvent

export type InboundSinkDeps = {
	remote: RemoteLike,
	-- The remote's name, used as the action prefix ("<name>.<action>").
	name: string,
	budget: RemoteBudget.RemoteBudget,
}

export type InboundSink = { Destroy: (self: InboundSink) -> () }

-- No action is ever budgeted on these remotes, so every one is unknown.
local SINK_ACTION = "Inbound"

local InboundSink = {}

function InboundSink.new(deps: InboundSinkDeps): InboundSink
	Deps.check(deps, "InboundSink", { "remote", "name", "budget" })

	local trove = Trove.new()
	local action = deps.name .. "." .. SINK_ACTION
	local budget = deps.budget
	trove:Connect(deps.remote.OnServerEvent, function(player: Player)
		budget:Take(player, action)
	end)

	return {
		Destroy = function(_self: InboundSink)
			trove:Destroy()
		end,
	}
end

return table.freeze(InboundSink)
