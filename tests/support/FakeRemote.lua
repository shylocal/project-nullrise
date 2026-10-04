--!strict
-- RemoteEvent stand-ins. Outbound calls are recorded in Sent as table.pack
-- results; Inject simulates an inbound message. FireAllClients records
-- FakeRemote.All in the player position.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.packages.Signal)

export type Packed = { n: number, [number]: any }

local FakeRemote = {}

FakeRemote.All = table.freeze({ Name = "FakeRemote.All" })

function FakeRemote.server(): any
	local remote = {
		OnServerEvent = Signal.new(),
		Sent = {} :: { Packed },
	}

	function remote.FireClient(self: any, player: any, ...: any)
		table.insert(self.Sent, table.pack(player, ...))
	end

	function remote.FireAllClients(self: any, ...: any)
		table.insert(self.Sent, table.pack(FakeRemote.All, ...))
	end

	function remote.Inject(self: any, player: any, ...: any)
		self.OnServerEvent:Fire(player, ...)
	end

	function remote.Clear(self: any)
		table.clear(self.Sent)
	end

	return remote
end

function FakeRemote.client(): any
	local remote = {
		OnClientEvent = Signal.new(),
		Sent = {} :: { Packed },
	}

	function remote.FireServer(self: any, ...: any)
		table.insert(self.Sent, table.pack(...))
	end

	function remote.Inject(self: any, ...: any)
		self.OnClientEvent:Fire(...)
	end

	function remote.Clear(self: any)
		table.clear(self.Sent)
	end

	return remote
end

return FakeRemote
