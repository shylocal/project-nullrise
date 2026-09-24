--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.packages
local Trove = require(Packages.Trove)

local WeaponsFolder = ReplicatedStorage.shared.weapons
local Fists = require(WeaponsFolder.Fists)

type WeaponDefinition = typeof(Fists)
type AnimationDefinition = WeaponDefinition.Animations["Equip"]

export type WeaponController = {
	Character: Model,
	Trove: typeof(Trove.new()),
	Equipped: WeaponDefinition?,
	Equip: (self: WeaponController, weapon: WeaponDefinition) -> (),
	Play: (self: WeaponController, animation_name: string) -> AnimationTrack?,
	Stop: (self: WeaponController, animation_name: string) -> (),
	Attack: (self: WeaponController, attack_index: number) -> AnimationTrack?,
	Destroy: (self: WeaponController) -> (),
}

local WeaponController = {}
WeaponController.__index = WeaponController

function WeaponController.new(character: Model): WeaponController
	local self = setmetatable({
		Character = character,
		Trove = Trove.new(),
		AnimationTrove = Trove.new(),
		Equipped = nil,
		Animator = nil,
		Tracks = {} :: { [string]: AnimationTrack },
	}, WeaponController)

	self:_start()

	return self
end

function WeaponController:_start()
	local humanoid = self.Character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		self:_watch_humanoid(humanoid)
	else
		self.Trove:Connect(
			self.Character.ChildAdded,
			function(child)
				if child:IsA("Humanoid") then
					self:_watch_humanoid(child)
				end
			end
		)
	end
end

function WeaponController:_watch_humanoid(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")

	if animator then
		self:_on_animator_added(animator)
	else
		self.Trove:Connect(
			humanoid.ChildAdded,
			function(child)
				if child:IsA("Animator") then
					self:_on_animator_added(child)
				end
			end
		)
	end
end

function WeaponController:_on_animator_added(animator: Animator)
	self.Animator = animator

	if self.Equipped then
		self:_load_tracks(self.Equipped)
		self:_play_equip()
	end
end

function WeaponController:_load_tracks(weapon: WeaponDefinition)
	self:_clear_tracks()

	local animator = self.Animator
	if not animator or animator.Parent == nil then
		return
	end

	for name, definition in pairs(weapon.Animations) do
		self.Tracks[name] = self:_load_track(animator, definition)
	end
end

function WeaponController:_load_track(animator: Animator, definition: AnimationDefinition): AnimationTrack
	local animation = Instance.new("Animation")
	animation.AnimationId = definition.Id

	local track = animator:LoadAnimation(animation)
	track.Priority = definition.Priority
	track.Looped = definition.Looped

	self.AnimationTrove:Add(animation)
	self.AnimationTrove:Add(track)

	return track
end

function WeaponController:_clear_tracks()
	self.AnimationTrove:Destroy()
	self.AnimationTrove = Trove.new()
	table.clear(self.Tracks)
end

function WeaponController:_play_equip()
	local equip = self:Play("Equip")
	if not equip then
		self:Play("Idle")
		return
	end

	self.AnimationTrove:Connect(
		equip.Ended,
		function()
			if self.Equipped and equip.Parent ~= nil then
				self:Play("Idle")
			end
		end
	)
end

function WeaponController:Equip(weapon: WeaponDefinition)
	self.Equipped = weapon

	self:_load_tracks(weapon)

	if self.Animator then
		self:_play_equip()
	end
end

function WeaponController:Play(animation_name: string): AnimationTrack?
	local track = self.Tracks[animation_name]
	if not track then
		return nil
	end

	local definition = self.Equipped and self.Equipped.Animations[animation_name]
	local transition_time = definition and definition.TransitionTime or 0

	track:Play(transition_time)

	return track
end

function WeaponController:Stop(animation_name: string)
	local track = self.Tracks[animation_name]
	if track then
		track:Stop()
	end
end

function WeaponController:Attack(attack_index: number): AnimationTrack?
	local weapon = self.Equipped
	if not weapon or not self.Animator then
		return nil
	end

	local attack = weapon.Attacks[attack_index]
	if not attack then
		return nil
	end

	local animation_name = "__attack_" .. attack_index
	local previous = self.Tracks[animation_name]
	if previous then
		previous:Stop()
		self.AnimationTrove:Remove(previous)
		self.Tracks[animation_name] = nil
	end

	local track = self:_load_track(self.Animator, attack.Animation)
	self.Tracks[animation_name] = track
	track:Play(attack.Animation.TransitionTime or 0)

	return track
end

function WeaponController:Destroy()
	self.AnimationTrove:Destroy()
	self.Trove:Destroy()
end

return WeaponController
