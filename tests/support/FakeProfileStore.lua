--!strict
-- In-memory stand-in for a ProfileStore (the StoreLike PlayerDataService
-- consumes). Saved data lives in `Saved` by key; a session copies it (or the
-- template) into a profile, and EndSession writes the profile's Data back.
--
-- Spec controls:
--   store.Fail[key] = true          StartSessionAsync returns nil for key
--   store.Error[key] = "message"    StartSessionAsync errors for key
--   store.BeforeReturn = fn(key, params)
--                                   runs inside StartSessionAsync before it
--                                   answers (simulates the yield: remove the
--                                   player here to leave while loading)
--   store.AfterStart = fn(profile)  runs on a new profile just before
--                                   StartSessionAsync returns it (patch its
--                                   methods here to make them throw)
--   store.IgnoreCancel = true      never consult params.Cancel (ProfileStore's
--                                   mock does not), so the caller must notice
--                                   the leave itself
--   store:Steal(key)                another server takes the session lock
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.packages.Signal)

local FakeProfileStore = {}
FakeProfileStore.__index = FakeProfileStore

local FakeProfile = {}
FakeProfile.__index = FakeProfile

local function deep_copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deep_copy(child)
	end
	return copy
end

-- ProfileStore's Reconcile: fills keys missing from Data with template
-- copies, recursing into tables present in both.
local function reconcile(target: any, template: any)
	for key, value in pairs(template) do
		if type(key) ~= "string" then
			continue
		end
		if target[key] == nil then
			target[key] = deep_copy(value)
		elseif type(target[key]) == "table" and type(value) == "table" then
			reconcile(target[key], value)
		end
	end
end

function FakeProfile.IsActive(self: any): boolean
	return self._active
end

function FakeProfile.AddUserId(self: any, user_id: number)
	if not table.find(self.UserIds, user_id) then
		table.insert(self.UserIds, user_id)
	end
end

function FakeProfile.Reconcile(self: any)
	reconcile(self.Data, self._store.Template)
end

function FakeProfile._end(self: any, save: boolean)
	if not self._active then
		return
	end
	self._active = false
	self.EndCount += 1
	if save then
		self._store.Saved[self.Key] = deep_copy(self.Data)
	end
	if self._store.Active[self.Key] == self then
		self._store.Active[self.Key] = nil
	end
	self.OnSessionEnd:Fire()
end

function FakeProfile.EndSession(self: any)
	self:_end(true)
end

function FakeProfileStore.new(template: any): any
	return setmetatable({
		Template = deep_copy(template),
		Saved = {} :: { [string]: any },
		Active = {} :: { [string]: any },
		Fail = {} :: { [string]: boolean },
		Error = {} :: { [string]: string },
		BeforeReturn = nil :: ((key: string, params: any) -> ())?,
		AfterStart = nil :: ((profile: any) -> ())?,
		IgnoreCancel = false,
		Calls = {} :: { string },
	}, FakeProfileStore)
end

function FakeProfileStore.StartSessionAsync(self: any, key: string, params: any): any
	table.insert(self.Calls, key)

	if self.BeforeReturn then
		self.BeforeReturn(key, params)
	end
	if self.Error[key] then
		error(self.Error[key], 0)
	end
	if self.Fail[key] then
		return nil
	end
	if not self.IgnoreCancel and params and params.Cancel and params.Cancel() then
		return nil
	end

	local saved = self.Saved[key]
	local profile = setmetatable({
		Key = key,
		Data = if saved ~= nil then deep_copy(saved) else deep_copy(self.Template),
		UserIds = {} :: { number },
		OnSessionEnd = Signal.new(),
		EndCount = 0,
		_active = true,
		_store = self,
	}, FakeProfile)
	self.Active[key] = profile
	if self.AfterStart then
		self.AfterStart(profile)
	end
	return profile
end

-- Simulates another server starting a session for key: the local profile
-- ends without saving and fires OnSessionEnd.
function FakeProfileStore.Steal(self: any, key: string)
	local profile = self.Active[key]
	if profile then
		profile:_end(false)
	end
end

return FakeProfileStore
