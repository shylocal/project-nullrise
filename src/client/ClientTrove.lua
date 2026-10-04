--!strict
-- Typed front for the Trove package (packages.Trove, Trove 1.8).
--
-- Trove's own `Trove` type is not reachable through the packages.Trove
-- re-export, and `typeof(Trove.new())` carries generic methods that the
-- analyzer fails to unify across modules: two copies of the same class type
-- then compare unequal. Client modules require this module instead of
-- packages.Trove and type their troves with the non-generic view below.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrovePackage = require(ReplicatedStorage.packages.Trove)

export type Trove = {
	Add: (self: any, object: any, cleanup_method: string?) -> any,
	Connect: (self: any, signal: any, fn: (...any) -> ...any) -> any,
	Extend: (self: any) -> Trove,
	Remove: (self: any, object: any) -> boolean,
	Clean: (self: any) -> (),
	Destroy: (self: any) -> (),
}

local ClientTrove = {}

function ClientTrove.new(): Trove
	-- Package boundary: a Trove 1.8 instance has every method listed above.
	return TrovePackage.new() :: any
end

return table.freeze(ClientTrove)
