--!strict
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
local Telemetry = require(script.Parent.Telemetry)

type PlayerSession = PlayerSession.PlayerSession
type Trove = PlayerSession.Trove

-- The hooks a component may implement; every hook is optional. Register
-- takes any table (components are instances of their own classes, which the
-- type checker cannot match against this shape), so this type documents the
-- contract and each component annotates its own hooks.
export type Component = {
	OnPlayerAdded: ((self: any, session: PlayerSession) -> ())?,
	OnCharacterAdded: ((self: any, session: PlayerSession, character: Model, trove: Trove) -> ())?,
	OnCharacterRemoving: ((self: any, session: PlayerSession, character: Model) -> ())?,
	OnPlayerRemoving: ((self: any, session: PlayerSession) -> ())?,
}

type Hook = "OnPlayerAdded" | "OnCharacterAdded" | "OnCharacterRemoving" | "OnPlayerRemoving"

type Registration = {
	Component: unknown,
	Name: string,
}

export type PlayerServiceDeps = {
	-- The Players service (a FakePlayers object in specs).
	players: Players,
	telemetry: Telemetry.Telemetry,
}

type PlayerServiceFields = {
	Trove: Trove,
	Sessions: { [Player]: PlayerSession },

	-- Vendored GoodSignal is untyped. Each fires (player: Player, session: PlayerSession).
	PlayerAdded: any,
	PlayerReady: any,
	PlayerRemoving: any,

	_players: Players,
	_telemetry: Telemetry.Telemetry,
	_components: { Registration },
	-- Per session, the components whose OnPlayerAdded completed.
	_completed: { [PlayerSession]: { [unknown]: boolean } },
	_started: boolean,
	_destroyed: boolean,
}

local PlayerService = {}
PlayerService.__index = PlayerService

export type PlayerService = typeof(setmetatable({} :: PlayerServiceFields, PlayerService))

function PlayerService.new(deps: PlayerServiceDeps): PlayerService
	Deps.check(deps, "PlayerService", { "players", "telemetry" })

	local fields: PlayerServiceFields = {
		Trove = Trove.new(),
		Sessions = {},

		PlayerAdded = Signal.new(),
		PlayerReady = Signal.new(),
		PlayerRemoving = Signal.new(),

		_players = deps.players,
		_telemetry = deps.telemetry,
		_components = {},
		_completed = {},
		_started = false,
		_destroyed = false,
	}
	local self = setmetatable(fields, PlayerService)

	self.Trove:Add(self.PlayerAdded)
	self.Trove:Add(self.PlayerReady)
	self.Trove:Add(self.PlayerRemoving)

	return self
end

function PlayerService.Register(self: PlayerService, component: unknown, name: string)
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

function PlayerService.Start(self: PlayerService)
	if self._started then
		error("PlayerService:Start called twice", 2)
	end
	self._started = true

	self.Trove:Connect(self._players.PlayerAdded, function(player: Player)
		task.spawn(self._join, self, player)
	end)

	self.Trove:Connect(self._players.PlayerRemoving, function(player: Player)
		self:_leave(player)
	end)

	-- Connect first, then process the players already in the server.
	for _, player in self._players:GetPlayers() do
		task.spawn(self._join, self, player)
	end
end

function PlayerService._report_failure(self: PlayerService, session: PlayerSession, registration: Registration, hook: Hook, err: unknown)
	warn(("[PlayerService] %s.%s failed for %s: %s"):format(
		registration.Name,
		hook,
		tostring(session.Player.Name),
		tostring(err)
	))
	self._telemetry:Count(session.Player, "Lifecycle", "ComponentFailed", registration.Name)
end

function PlayerService._call(self: PlayerService, session: PlayerSession, registration: Registration, hook: Hook, ...: any): boolean
	-- Hooks are looked up by name on a table checked in Register; Component
	-- documents their signatures.
	local callback = (registration.Component :: any)[hook]
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
function PlayerService._dispatch_character_added(self: PlayerService, session: PlayerSession, character: Model)
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

function PlayerService._dispatch_character_removing(self: PlayerService, session: PlayerSession, character: Model)
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

-- A function rather than an inline comparison: Phase changes while a hook
-- yields, which a narrowed local type would not reflect.
local function is_leaving(session: PlayerSession): boolean
	return session.Phase == "Leaving"
end

function PlayerService._join(self: PlayerService, player: Player)
	if self._destroyed or player.Parent ~= self._players or self.Sessions[player] then
		return
	end

	local ok, result = pcall(PlayerSession.new, player)
	if not ok then
		warn(("[PlayerService] could not create a session for %s: %s"):format(tostring(player.Name), tostring(result)))
		return
	end
	local session: PlayerSession = result

	local completed: { [unknown]: boolean } = {}
	self.Sessions[player] = session
	self._completed[session] = completed

	-- PlayerSession fires its character signals before releasing the
	-- character, so components still see the character's trove intact.
	session.Trove:Connect(session.CharacterAdded, function(character: Model)
		if session.Phase == "Ready" then
			self:_dispatch_character_added(session, character)
		end
	end)

	session.Trove:Connect(session.CharacterRemoving, function(character: Model)
		if session.Phase == "Ready" then
			self:_dispatch_character_removing(session, character)
		end
	end)

	self.PlayerAdded:Fire(player, session)

	for _, registration in self._components do
		if is_leaving(session) then
			return
		end

		if self:_call(session, registration, "OnPlayerAdded") then
			completed[registration.Component] = true
		end

		-- A yielding hook may resume after the player left; leave already
		-- tore down every completed component, so stop here.
		if is_leaving(session) then
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

function PlayerService._leave(self: PlayerService, player: Player)
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

function PlayerService.Get(self: PlayerService, player: Player): PlayerSession?
	return self.Sessions[player]
end

function PlayerService.GetReady(self: PlayerService, player: Player): PlayerSession?
	local session = self.Sessions[player]
	if session and session.Phase == "Ready" then
		return session
	end
	return nil
end

-- Every live session, in any phase. Components use it to release their
-- per-session state when they are destroyed before PlayerService.
function PlayerService.GetSessions(self: PlayerService): { PlayerSession }
	local sessions = {}
	for _, session in self.Sessions do
		table.insert(sessions, session)
	end
	return sessions
end

function PlayerService.Destroy(self: PlayerService)
	if self._destroyed then
		return
	end
	self._destroyed = true

	local players = {}
	for player in self.Sessions do
		table.insert(players, player)
	end
	for _, player in players do
		self:_leave(player)
	end

	self.Trove:Destroy()
end

return PlayerService
