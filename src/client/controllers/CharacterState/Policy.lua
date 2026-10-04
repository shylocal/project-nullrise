--!strict
-- Which actions each active character activity blocks. Client-side because
-- only client controllers consult it. CharacterState validates this table.
local Policy: { [string]: { string } } = {
	Attack = {},
	AttackRooted = { "Sprint" },
	Hang = { "Attack", "Charge", "Sprint", "Vault" },
	Mantle = { "Attack", "Charge", "Sprint", "Vault", "Grab" },
	Vault = { "Attack", "Charge", "Sprint", "Vault", "Grab" },
	TopHop = { "Vault" },
	Stunned = { "Attack", "Charge", "Sprint", "Vault", "Grab" },
}

for _, actions in Policy do
	table.freeze(actions)
end

return table.freeze(Policy)
