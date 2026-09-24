--!strict

local Players = game:GetService("Players")

local PlayerController = require(script.Parent.controllers.PlayerController)

local local_player = Players.LocalPlayer
assert(local_player, "project-nullrise: LocalPlayer is unavailable")

local controller = PlayerController.new(local_player)

-- The controller owns its connections and will clean itself up on PlayerRemoving.
-- Keeping this reference in the bootstrap module prevents accidental collection
-- and makes the root lifecycle explicit.
return controller
