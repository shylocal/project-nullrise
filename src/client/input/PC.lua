local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.packages.Trove)
local Actions = require(ReplicatedStorage.shared.input.Actions)

local PCInput = {}
PCInput.__index = PCInput

local SPRINT_KEYS = {
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift,
}

local function is_sprint_key(key_code)
	return key_code == Enum.KeyCode.LeftShift or key_code == Enum.KeyCode.RightShift
end

local Bindings = {
	[Enum.UserInputType.MouseButton1] = Actions.Primary,
	[Enum.KeyCode.LeftShift] = Actions.Sprint,
	[Enum.KeyCode.RightShift] = Actions.Sprint,
	[Enum.KeyCode.Space] = Actions.Jump,
	[Enum.KeyCode.W] = Actions.Forward,
	[Enum.KeyCode.S] = Actions.Backward,
	[Enum.KeyCode.A] = Actions.Left,
	[Enum.KeyCode.D] = Actions.Right,
	[Enum.KeyCode.One] = Actions.Slot1,
	[Enum.KeyCode.Two] = Actions.Slot2,
}

function PCInput.new(on_began, on_ended)
	local self = setmetatable({ Trove = Trove.new() }, PCInput)
	local ok, err = pcall(self._start, self, on_began, on_ended)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- Shift is an aliased action with two physical keys. On release, reconcile
-- both keys against UserInputService so a missed/stale end edge cannot leave
-- Sprint held until that same key is pressed and released again.
function PCInput._release_unheld_sprint_keys(on_ended, released_key, is_key_down)
	local left_down = is_key_down(Enum.KeyCode.LeftShift)
	local right_down = is_key_down(Enum.KeyCode.RightShift)
	warn(("[InputDebug][PC] reconcile released=%s leftDown=%s rightDown=%s"):format(
		tostring(released_key), tostring(left_down), tostring(right_down)
	))
	for _, key_code in ipairs(SPRINT_KEYS) do
		if key_code == released_key or not is_key_down(key_code) then
			warn(("[InputDebug][PC] emit Sprint end sourceId=%s"):format(tostring(key_code)))
			on_ended(Actions.Sprint, "PC", key_code)
		end
	end
end

function PCInput:_start(on_began, on_ended)
	self.Trove:Connect(UserInputService.InputBegan, function(input, game_processed)
		if game_processed then return end
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action then
			warn(("[InputDebug][PC] InputBegan key=%s type=%s action=%s sourceId=%s processed=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(action), tostring(source_id), tostring(game_processed)))
			on_began(action, "PC", source_id)
		end
	end)
	self.Trove:Connect(UserInputService.InputEnded, function(input)
		local action = Bindings[input.UserInputType] or Bindings[input.KeyCode]
		local source_id = input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode or input.UserInputType
		if action == Actions.Sprint or is_sprint_key(input.KeyCode) then
			warn(("[InputDebug][PC] InputEnded key=%s type=%s action=%s sourceId=%s"):format(tostring(input.KeyCode), tostring(input.UserInputType), tostring(action), tostring(source_id)))
			PCInput._release_unheld_sprint_keys(on_ended, input.KeyCode, function(key_code)
				return UserInputService:IsKeyDown(key_code)
			end)
		elseif action then
			on_ended(action, "PC", source_id)
		end
	end)
end

function PCInput:Destroy()
	self.Trove:Destroy()
end

return PCInput
