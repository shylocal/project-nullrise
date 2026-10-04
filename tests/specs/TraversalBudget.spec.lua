local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.packages.Signal)
local Actions = require(ReplicatedStorage.shared.input.Actions)
local Config = require(ReplicatedStorage.shared.config)
local Controllers = StarterPlayer.StarterPlayerScripts.client.controllers
local CharacterState = require(Controllers.CharacterState)
local Policy = require(Controllers.CharacterState.Policy)
local ParkourController = require(Controllers.ParkourController)
local ClimbableIndex = require(Controllers.ParkourController.ClimbableIndex)
local Metrics = require(Controllers.ParkourController.Metrics)
local State = require(Controllers.ParkourController.State)
local Traversal = require(Controllers.ParkourController.Traversal)

local CENTER = Vector3.new(70000, 500, 70000)
local FRAMES = 30
local DT = 1 / 60

local function make_part(name, size, cframe, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Parent = parent
	return part
end

return function()
	describe("Parkour traversal frame budget", function()
		it("reuses an empty corner fan while traversal is blocked at a ledge end", function()
			local Parkour = Config.Parkour
			local world = Instance.new("Folder")
			world.Name = "TraversalBudgetSpec"
			world.Parent = Workspace

			-- A tagged ledge (x in [-5, 5], wall face at z = +1, top at y = +3)
			-- that ends against a solid, untagged wall, so there is neither a
			-- straight continuation nor a corner to wrap around.
			local ledge = make_part("Ledge", Vector3.new(10, 6, 2), CFrame.new(CENTER), world)
			make_part("EndWall", Vector3.new(1, 10, 8), CFrame.new(CENTER + Vector3.new(5.7, 0, 2)), world)
			local face_z = CENTER.Z + 1
			local top_y = CENTER.Y + 3

			local character = Instance.new("Model")
			character.Name = "TraversalBudgetSpecCharacter"
			local normal = Vector3.zAxis
			local hang_position = Vector3.new(CENTER.X + 4.9, top_y - Parkour.HangDrop, face_z - 0.1 + Parkour.WallGap)
			local root = make_part(
				"HumanoidRootPart",
				Vector3.new(2, 2, 1),
				CFrame.lookAt(hang_position, hang_position - normal),
				character
			)
			root.CanCollide = false
			local humanoid = Instance.new("Humanoid")
			humanoid.RequiresNeck = false
			humanoid.Parent = character
			character.Parent = world

			local input = { ActionBegan = Signal.new(), ActionEnded = Signal.new(), Down = {} }
			function input:IsDown(action)
				return self.Down[action] == true
			end
			input.Down[Actions.Jump] = true
			input.Down[Actions.Right] = true
			local movement = {}
			function movement:IsSprinting()
				return false
			end
			local state = CharacterState.new({ policy = Policy })
			local controller = ParkourController.new({
				character = character,
				input = input,
				movement = movement,
				state = state,
			})
			-- Use an index over just this ledge so the spec does not depend on
			-- tag signal timing.
			local index = ClimbableIndex.new({
				collection = {
					GetTagged = function()
						return { ledge }
					end,
					GetInstanceAddedSignal = function()
						return Signal.new()
					end,
					GetInstanceRemovedSignal = function()
						return Signal.new()
					end,
				},
				tag = Config.World.Tags.Climbable,
				cell_size = 16,
				root = Workspace,
			})
			controller.Climbables = index

			expect(State.enter(controller, {
				kind = "Hanging",
				data = {
					CurrentClimbable = ledge,
					Normal = normal,
					HangDepthOffset = normal * Parkour.WallGap,
					HangPosition = hang_position,
				},
			})).to.equal(true)

			local rays = {}
			local times = {}
			for frame = 1, FRAMES do
				Metrics.begin_frame(controller)
				times[frame] = os.clock()
				Traversal.traverse(controller, DT)
				rays[frame] = Metrics.snapshot(controller).RaysThisFrame
				if frame == 1 then
					-- The first frame ran the fan, found nothing, and recorded it.
					expect(controller.CornerProbeMiss ~= nil).to.equal(true)
				end
			end

			-- Still hanging at the same spot: traversal was blocked throughout.
			local hang = State.hang(controller)
			expect(hang ~= nil).to.equal(true)
			expect((hang.HangPosition - hang_position).Magnitude < 1e-3).to.equal(true)

			local uncached = rays[1]
			local cached_frames = 0
			for frame = 2, FRAMES do
				if times[frame] - times[1] < Parkour.CornerProbeMissTtl then
					cached_frames += 1
					expect(rays[frame] < uncached).to.equal(true)
				end
			end
			expect(cached_frames > 0).to.equal(true)

			controller:Destroy()
			state:Destroy()
			index:Destroy()
			input.ActionBegan:Destroy()
			input.ActionEnded:Destroy()
			world:Destroy()
		end)
	end)
end
