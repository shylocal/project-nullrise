-- Combat timing shared by client and server. Per-attack timing lives on the
-- weapon definitions; these values only cover network behaviour.
local Validator = require(script.Parent.Validator)

local CombatConfig = {
	-- Seconds of network jitter the server tolerates when comparing the arrival
	-- time of two packets from the same client (Attack -> HitStart, etc.).
	TimingTolerance = 0.1,

	-- Seconds the client waits for AttackAccepted/AttackRejected before it
	-- gives up on a pending attack and allows new input again.
	PendingAttackTimeout = 1,
}

local ok, reason = Validator.validate_combat_config(CombatConfig)
if not ok then
	error(("Invalid combat config: %s"):format(reason), 0)
end

return CombatConfig
