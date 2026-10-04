--!strict
-- Token-bucket budgets for inbound remote traffic, per player. Rate is tokens
-- per second, Burst is the bucket capacity. Action keys are "<Remote>.<Action>".
local Network = {
	RemoteBudget = {
		Global = { Rate = 60, Burst = 120 },
		Actions = {
			["Combat.Attack"] = { Rate = 12, Burst = 3 },
			["Combat.HitStart"] = { Rate = 50, Burst = 4 },
			["Combat.HitStop"] = { Rate = 50, Burst = 4 },
			["Combat.Hit"] = { Rate = 60, Burst = 16 },
			["Inventory.SelectSlot"] = { Rate = 12, Burst = 3 },
			["Inventory.SelectUid"] = { Rate = 12, Burst = 3 },
		},
	},
}

export type Rate = { Rate: number, Burst: number }
export type NetworkConfig = { RemoteBudget: { Global: Rate, Actions: { [string]: Rate } } }

return Network :: NetworkConfig
