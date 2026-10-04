--!strict
local Data = {
	StoreName = "PlayerData",
	KeyPrefix = "Player_",
	-- Studio sessions use the ProfileStore mock so test runs never touch live data.
	UseMockInStudio = true,
}

export type DataConfig = typeof(Data)

return Data
