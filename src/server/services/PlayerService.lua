-- Owns every PlayerSession and drives registered components through the
-- player lifecycle in a fixed order:
--   join:  OnPlayerAdded (in registration order, may yield) -> Ready ->
--          OnCharacterAdded for the current character
--   character events (Ready only): OnCharacterAdded in order,
--          OnCharacterRemoving in reverse order
--   leave: Leaving -> OnCharacterRemoving (reverse) -> OnPlayerRemoving
--          (reverse, only for components whose OnPlayerAdded completed) ->
--          session destroyed
-- Remote handlers should act only on GetReady sessions.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)
local Signal = require(Packages.Signal)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)

local PlayerSession = require(script.Parent.PlayerSession)

export type Component = {
	OnPlayerAdded: ((self: any, session: any) -> ())?,
	OnCharacterAdded: ((self: any, session: any, character: Model, trove: any) -> ())?,
	OnCharacterRemoving: ((self: any, session: any, character: Model) -> ())?,
	OnPlayerRemoving: ((self: any, session: any) -> ())?,
}

type Registration = {
	Component: Component,
	Name: string,
}

local PlayerService = {}
PlayerService.__index = PlayerService

function PlayerService.new(deps)
	Deps.check(deps, "PlayerService", { "players", "telemetry" })

	local self = setmetatable({
		Trove = Trove.new(),
		Sessions = {},

		PlayerAdded = Signal.new(),
		PlayerReady = Signal.new(),
		PlayerRemoving = Signal.new(),

		_players = deps.players,
		_telemetry = deps.telemetry,
		_components = {} :: { Registration },
		_completed = {},
		_started = false,
		_destroyed = false,
	}, PlayerService)

	self.Trove:Add(self.PlayerAdded)
	self.Trove:Add(self.PlayerReady)
	self.Trove:Add(self.PlayerRemoving)

	return self
end

function PlayerService:Register(component, name)
	if self._started or self._destroyed then
		error(("PlayerService:Register(%s) called after Start"):format(tostring(name)), 2)
	end
	if type(component) ~= "table" then
		error("PlayerService:Register: component must be a table", 2)
	end
	if type(name) ~= "string" or name == "" then
		error("PlayerService:Register: name must be a non-empty string", 2)
	end

	for _, registration in self._components do
		if registration.Component == component or registration.Name == name then
			error(("PlayerService:Register: %s is already registered"):format(name), 2)
		end
	end

	table.insert(self._components, {
		Component = component,
		Name = name,
	})
end

function PlayerService:Start()
	if self._started then
		error("PlayerService:Start called twice", 2)
	end
	self._started = true

	self.Trove:Connect(self._players.PlayerAdded, function(player)
		task.spawn(self._join, self, player)
	end)

	self.Trove:Connect(self._players.PlayerRemoving, function(player)
		self:_leave(player)
	end)

	-- Connect first, then process the players already in the server.
	for _, player in self._players:GetPlayers() do
		task.spawn(self._join, self, player)
	end
end

function PlayerService:_report_failure(session, registration, hook, err)
	warn(("[PlayerService] %s.%s failed for %s: %s"):format(
		registration.Name,
		hook,
		tostring(session.Player.Name),
		tostring(err)
	))
	self._telemetry:Count(session.Player, "Lifecycle", "ComponentFailed", registration.Name)
end

function PlayerService:_call(session, registration, hook, ...)
	local callback = registration.Component[hook]
	if not callback then
		return true
	end

	local ok, err = pcall(callback, registration.Component, session, ...)
	if not ok then
		self:_report_failure(session, registration, hook, err)
	end
	return ok
end

-- Character hooks reach only components whose OnPlayerAdded completed; a
-- component that failed to load has no session state to act on.
function PlayerService:_dispatch_character_added(session, character)
	local completed = self._completed[session]
	if not completed then
		return
	end

	for _, registration in self._components do
		if session.Character ~= character or session.Phase ~= "Ready" then
			return
		end
		if completed[registration.Component] then
			self:_call(session, registration, "OnCharacterAdded", character, session.CharacterTrove)
		end
	end
end

function PlayerService:_dispatch_character_removing(session, character)
	local completed = self._completed[session]
	if not completed then
		return
	end

	local components = self._components
	for index = #components, 1, -1 do
		local registration = components[index]
		if completed[registration.Component] then
			self:_call(session, registration, "OnCharacterRemoving", character)
		end
	end
end

function PlayerService:_join(player)
	if self._destroyed or player.Parent ~= self._players or self.Sessions[player] then
		return
	end

	local ok, session = pcall(PlayerSession.new, player)
	if not ok then
		warn(("[PlayerService] could not create a session for %s: %s"):format(tostring(player.Name), tostring(session)))
		return
	end

	local completed = {}
	self.Sessions[player] = session
	self._completed[session] = completed

	-- PlayerSession fires its character signals before releasing the
	-- character, so components still see the character's trove intact.
	session.Trove:Connect(session.CharacterAdded, function(character)
		if session.Phase == "Ready" then
			self:_dispatch_character_added(session, character)
		end
	end)

	session.Trove:Connect(session.CharacterRemoving, function(character)
		if session.Phase == "Ready" then
			self:_dispatch_character_removing(session, character)
		end
	end)

	self.PlayerAdded:Fire(player, session)

	for _, registration in self._components do
		if session.Phase == "Leaving" then
			return
		end

		if self:_call(session, registration, "OnPlayerAdded") then
			completed[registration.Component] = true
		end

		-- A yielding hook may resume after the player left; leave already
		-- tore down every completed component, so stop here.
		if session.Phase == "Leaving" then
			return
		end
	end

	session.Phase = "Ready"
	self.PlayerReady:Fire(player, session)

	local character = session.Character
	if character then
		self:_dispatch_character_added(session, character)
	end
end

function PlayerService:_leave(player)
	local session = self.Sessions[player]
	if not session or session.Phase == "Leaving" then
		return
	end

	local was_ready = session.Phase == "Ready"
	session.Phase = "Leaving"
	self.PlayerRemoving:Fire(player, session)

	local character = session.Character
	if was_ready and character then
		self:_dispatch_character_removing(session, character)
	end

	local completed = self._completed[session] or {}
	local components = self._components
	for index = #components, 1, -1 do
		local registration = components[index]
		if completed[registration.Component] then
			self:_call(session, registration, "OnPlayerRemoving")
		end
	end

	self.Sessions[player] = nil
	self._completed[session] = nil
	session:Destroy()

	self._telemetry:Forget(player)
end

function PlayerService:Get(player)
	return self.Sessions[player]
end

function PlayerService:GetReady(player)
	local session = self.Sessions[player]
	if session and session.Phase == "Ready" then
		return session
	end
	return nil
end

-- Every live session, in any phase. Components use it to release their
-- per-session state when they are destroyed before PlayerService.
function PlayerService:GetSessions()
	local sessions = {}
	for _, session in pairs(self.Sessions) do
		table.insert(sessions, session)
	end
	return sessions
end

function PlayerService:GetPlayers()
	return self._players:GetPlayers()
end

function PlayerService:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local players = {}
	for player in pairs(self.Sessions) do
		table.insert(players, player)
	end
	for _, player in players do
		self:_leave(player)
	end

	self.Trove:Destroy()
end

return PlayerService
