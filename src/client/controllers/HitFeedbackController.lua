local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local HitFeedbackController = {}
HitFeedbackController.__index = HitFeedbackController

function HitFeedbackController.new(combat_controller)
	local self = setmetatable({
		Trove = Trove.new(),
		FadeTween = nil,
		Stroke = nil,
	}, HitFeedbackController)

	self:_start(combat_controller)

	return self
end

function HitFeedbackController:_start(combat_controller)
	local player = Players.LocalPlayer
	local player_gui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player_gui
	self.Trove:Add(gui)

	local marker = Instance.new("TextLabel")
	marker.Name = "Hitmarker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.fromScale(0.5, 0.5)
	marker.Size = UDim2.fromOffset(32, 32)
	marker.BackgroundTransparency = 1
	marker.Text = "×"
	marker.TextSize = 28
	marker.Font = Enum.Font.GothamBold
	marker.TextTransparency = 1
	marker.ZIndex = 10
	marker.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1.5
	stroke.Transparency = 0.15
	stroke.Parent = marker

	self.Stroke = stroke

	self.Trove:Connect(
		combat_controller.Hit,
		function()
			self:_show(marker)
		end
	)
end

function HitFeedbackController:_show(marker)
	if self.FadeTween then
		self.FadeTween:Cancel()
	end

	marker.TextTransparency = 0
	self.Stroke.Transparency = 0.15
	marker.TextSize = 30

	self.FadeTween = TweenService:Create(
		marker,
		TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			TextTransparency = 1,
			TextSize = 24,
		}
	)

	self.FadeTween:Play()
end

function HitFeedbackController:Destroy()
	if self.FadeTween then
		self.FadeTween:Cancel()
		self.FadeTween = nil
	end

	self.Trove:Destroy()
end

return HitFeedbackController
