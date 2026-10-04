--!strict
-- Session-lifetime mirror of the server's inventory and equipped weapon. It is
-- the only listener on the Inventory and Weapon remotes. The server is the
-- source of truth: selection requests never change local state directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.packages.Trove)
local Signal = require(ReplicatedStorage.packages.Signal)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local Protocol = require(ReplicatedStorage.shared.network.Protocol)
local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)

export type ClientRemoteLike = {
	OnClientEvent: any,
	FireServer: (self: any, ...any) -> (),
}

export type InventoryEntry = { Slot: number, WeaponId: string }

export type Deps = {
	inventory_remote: ClientRemoteLike,
	weapon_remote: ClientRemoteLike,
}

local LoadoutClient = {}
LoadoutClient.__index = LoadoutClient

function LoadoutClient.is_valid_inventory(entries: any, selected_slot: any): boolean
	if typeof(entries) ~= "table" then
		return false
	end
	if selected_slot ~= nil and typeof(selected_slot) ~= "number" then
		return false
	end

	for _, entry in ipairs(entries) do
		if typeof(entry) ~= "table"
			or typeof(entry.Slot) ~= "number"
			or typeof(entry.WeaponId) ~= "string" then
			return false
		end
	end

	return true
end

local function freeze_entries(entries: { any }): { InventoryEntry }
	local copy = table.create(#entries)
	for index, entry in ipairs(entries) do
		copy[index] = table.freeze({ Slot = entry.Slot, WeaponId = entry.WeaponId })
	end
	return table.freeze(copy)
end

function LoadoutClient.new(deps: Deps)
	Deps.check(deps, "LoadoutClient", { "inventory_remote", "weapon_remote" })

	local self = setmetatable({
		InventoryRemote = deps.inventory_remote,
		WeaponRemote = deps.weapon_remote,
		Trove = Trove.new(),
		EquippedId = Catalog.DefaultId,
		Entries = table.freeze({}) :: { InventoryEntry },
		-- 0 = nothing selected (the default weapon).
		SelectedSlot = 0,
		EquippedChanged = Signal.new(),
		InventoryChanged = Signal.new(),
		_destroyed = false,
	}, LoadoutClient)

	self.Trove:Add(self.EquippedChanged)
	self.Trove:Add(self.InventoryChanged)

	self.Trove:Connect(deps.weapon_remote.OnClientEvent, function(action: any, weapon_id: any)
		if self._destroyed or action ~= Protocol.Weapon.Equipped or typeof(weapon_id) ~= "string" then
			return
		end

		-- Fired on every Equipped event, including a repeat of the same id:
		-- each one resets combat and replays the equip animation.
		self.EquippedId = weapon_id
		self.EquippedChanged:Fire(weapon_id)
	end)

	self.Trove:Connect(deps.inventory_remote.OnClientEvent, function(action: any, entries: any, selected_slot: any)
		if self._destroyed or action ~= Protocol.Inventory.Changed then
			return
		end
		if not LoadoutClient.is_valid_inventory(entries, selected_slot) then
			warn("LoadoutClient: ignoring malformed Inventory.Changed payload")
			return
		end

		local frozen = freeze_entries(entries)
		local slot = if selected_slot == nil then 0 else selected_slot
		self.Entries = frozen
		self.SelectedSlot = slot
		self.InventoryChanged:Fire(frozen, slot)
	end)

	return self
end

function LoadoutClient:SelectSlot(slot: number)
	if self._destroyed then
		return
	end
	self.InventoryRemote:FireServer(Protocol.Inventory.SelectSlot, slot)
end

-- Phase 1 only; Phase 2 replaces this with SelectUid / SelectWeapon.
function LoadoutClient:SelectItem(weapon_id: string)
	if self._destroyed then
		return
	end
	self.InventoryRemote:FireServer(Protocol.Inventory.SelectItem, weapon_id)
end

function LoadoutClient:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self.Trove:Destroy()
end

return LoadoutClient
