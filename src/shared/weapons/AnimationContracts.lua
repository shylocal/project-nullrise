--!strict
-- Checks weapon timing against baked animation data (marker times, lengths).
-- Phase 1 stub: always passes. Implemented by P2-content against the move schema.
local AnimationContracts = {}

function AnimationContracts.check(_definition: any, _id: string, _manifest: any): { string }
	return {}
end

return table.freeze(AnimationContracts)
