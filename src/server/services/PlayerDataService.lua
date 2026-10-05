--!strict
-- Loads, session-locks and releases each player's persisted profile. It is
-- the first PlayerService component, so every later component can read the
-- profile in its own OnPlayerAdded.
--
-- The store is injected (ProfileStore, its mock, or a spec fake). A profile
-- that cannot be loaded kicks the player on live servers; in Studio the
-- player gets an in-memory default profile that is never saved, so play
-- testing works without API access. Profile.Data is the live table: only
-- InventoryService writes Inventory, and every write is saved by the store.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.shared.config)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local ItemCatalog = require(ReplicatedStorage.shared.items.ItemCatalog)
local Schema = require(ReplicatedStorage.shared.data.Schema)

local PlayerService = require(script.Parent.PlayerService)
local PlayerSession = require(script.Parent.PlayerSession)
local Telemetry = require(script.Parent.Telemetry)

type PlayerService = PlayerService.PlayerService
type PlayerSession = PlayerSession.PlayerSession

-- Vendor boundary: ProfileStore (or its mock, or a spec fake). Methods take
-- the vendor's own object as `self`, and Data is unvalidated until
-- Schema.migrate has run.
export type ConnectionLike = { Disconnect: (self: any) -> () }
export type SignalLike = { Connect: (self: any, listener: () -> ()) -> ConnectionLike }

export type ProfileLike = {
	Data: any,
	AddUserId: (self: any, user_id: number) -> (),
	Reconcile: (self: any) -> (),
	EndSession: (self: any) -> (),
	OnSessionEnd: SignalLike,
	IsActive: (self: any) -> boolean,
}

-- IsClosing mirrors ProfileStore.IsClosing (true once BindToClose ran); a
-- store without it never reports closing.
export type StoreLike = {
	StartSessionAsync: (self: any, key: string, params: { Cancel: () -> boolean }) -> ProfileLike?,
	IsClosing: boolean?,
}

export type Deps = {
	players: PlayerService,
	store: StoreLike,
	is_studio: boolean,
	config: Config.DataConfig,
	telemetry: Telemetry.Telemetry,
}

type State = {
	Profile: ProfileLike?,
	Data: Schema.ProfileDataV1,
	Persistent: boolean,
	Ended: boolean,
	Connection: ConnectionLike?,
	Destroy: (self: State) -> (),
}

local LOAD_FAILED_MESSAGE = "Your data failed to load. Please rejoin."
local SESSION_ENDED_MESSAGE = "Your data was opened on another server."

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

PlayerDataService.LOAD_FAILED_MESSAGE = LOAD_FAILED_MESSAGE
PlayerDataService.SESSION_ENDED_MESSAGE = SESSION_ENDED_MESSAGE

-- Releases the profile at most once. The OnSessionEnd listener is
-- disconnected first so a release we started never reads as a remote steal.
local function end_state(state: State)
	if state.Ended then
		return
	end
	state.Ended = true

	local connection = state.Connection
	state.Connection = nil
	if connection then
		connection:Disconnect()
	end

	local profile = state.Profile
	if profile and profile:IsActive() then
		profile:EndSession()
	end
end

local function new_state(profile: ProfileLike?, data: Schema.ProfileDataV1, persistent: boolean): State
	return {
		Profile = profile,
		Data = data,
		Persistent = persistent,
		Ended = false,
		Connection = nil,
		Destroy = end_state,
	}
end

-- Writes the Starter loadout into a profile that has never been seeded, so
-- existing and new players start with today's items. Occupied slots are
-- kept; the loadout is applied once per profile.
local function seed(data: Schema.ProfileDataV1)
	local inventory = data.Inventory
	if inventory.Seeded == true then
		return
	end

	local slots = inventory.Slots
	for slot, weapon_id in pairs(Catalog.Loadout("Starter")) do
		local item = ItemCatalog.ForWeapon(weapon_id)
		local key = tostring(slot)
		if item and slots[key] == nil then
			slots[key] = {
				Uid = HttpService:GenerateGUID(false),
				ItemId = item.Id,
				Data = {},
			}
		end
	end

	inventory.Seeded = true
end

type PlayerDataServiceFields = {
	_players: PlayerService,
	_store: StoreLike,
	_is_studio: boolean,
	_config: Config.DataConfig,
	_telemetry: Telemetry.Telemetry,
}

export type PlayerDataService = typeof(setmetatable({} :: PlayerDataServiceFields, PlayerDataService))

function PlayerDataService.new(deps: Deps): PlayerDataService
	Deps.check(deps, "PlayerDataService", { "players", "store", "is_studio", "config", "telemetry" })

	local fields: PlayerDataServiceFields = {
		_players = deps.players,
		_store = deps.store,
		_is_studio = deps.is_studio,
		_config = deps.config,
		_telemetry = deps.telemetry,
	}
	local self = setmetatable(fields, PlayerDataService)

	deps.players:Register(self, "PlayerDataService")

	return self
end

function PlayerDataService._load(self: PlayerDataService, session: PlayerSession): (ProfileLike?, string?)
	local key = self._config.KeyPrefix .. tostring(session.UserId)
	local ok, result = pcall(self._store.StartSessionAsync, self._store, key, {
		Cancel = function(): boolean
			return session.Phase == "Leaving"
		end,
	})
	if not ok then
		return nil, ("StartSessionAsync failed: %s"):format(tostring(result))
	end
	if result == nil then
		return nil, "the profile session could not be started"
	end
	return result, nil
end

-- Live servers kick; Studio continues on an unsaved default profile.
function PlayerDataService._fail(self: PlayerDataService, session: PlayerSession, reason: string)
	local player = session.Player
	self._telemetry:Count(player, "Data", "LoadFailed")

	if not self._is_studio then
		warn(("[PlayerData] %s for %s (%d); kicking"):format(reason, tostring(player.Name), session.UserId))
		player:Kick(LOAD_FAILED_MESSAGE)
		return
	end

	warn(("[PlayerData] %s for %s; using an in-memory default profile that is not saved"):format(
		reason,
		tostring(player.Name)
	))
	local data = Schema.Template()
	seed(data)
	session:Set(self, new_state(nil, data, false))
end

function PlayerDataService.OnPlayerAdded(self: PlayerDataService, session: PlayerSession)
	local player = session.Player
	local profile, load_error = self:_load(session)

	-- The player left while the session was starting: release it at once.
	if session.Phase == "Leaving" then
		if profile then
			profile:EndSession()
		end
		return
	end

	if profile == nil then
		self:_fail(session, load_error or "the profile could not be loaded")
		return
	end

	profile:AddUserId(session.UserId)
	profile:Reconcile()

	local data, migrate_error = Schema.migrate(profile.Data)
	if data == nil then
		-- Never keep a session we cannot read: leave the saved data untouched.
		profile:EndSession()
		self:_fail(session, ("profile data is unusable (%s)"):format(tostring(migrate_error)))
		return
	end

	for _, warning in Schema.sanitize(data) do
		warn(("[PlayerData] %s: %s"):format(tostring(player.Name), warning))
		self._telemetry:Count(player, "Data", "Sanitized")
	end

	seed(data)

	local state = new_state(profile, data, true)
	state.Connection = profile.OnSessionEnd:Connect(function()
		if state.Ended then
			return
		end
		state.Ended = true
		state.Connection = nil
		-- Another server took the session lock: this copy is no longer saved.
		-- A server shutdown also ends every session; that is not a steal.
		if self._store.IsClosing == true then
			return
		end
		if self._players:Get(player) == session and session.Phase ~= "Leaving" then
			self._telemetry:Count(player, "Data", "SessionEnded")
			player:Kick(SESSION_ENDED_MESSAGE)
		end
	end)

	session:Set(self, state)
end

function PlayerDataService.OnPlayerRemoving(self: PlayerDataService, session: PlayerSession)
	session:Clear(self)
end

function PlayerDataService._state(self: PlayerDataService, player: Player): State?
	local session = self._players:Get(player)
	if not session or session.Phase == "Leaving" then
		return nil
	end
	return session:Get(self) :: State?
end

-- The live profile data, or nil when the player has no loaded profile.
function PlayerDataService.GetData(self: PlayerDataService, player: Player): Schema.ProfileDataV1?
	local state = self:_state(player)
	return state and state.Data
end

-- True while the player's data is backed by an active store session.
function PlayerDataService.IsPersistent(self: PlayerDataService, player: Player): boolean
	local state = self:_state(player)
	return state ~= nil and state.Persistent and not state.Ended
end

function PlayerDataService.Destroy(self: PlayerDataService)
	for _, session in self._players:GetSessions() do
		session:Clear(self)
	end
end

return PlayerDataService
