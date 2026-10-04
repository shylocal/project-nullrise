--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Actions = require(ReplicatedStorage.shared.input.Actions)
local InputLatch = require(StarterPlayer.StarterPlayerScripts.client.controllers.ParkourController.InputLatch)

-- A CharacterState.Handle stand-in that counts pops. It is `any` because
-- Block takes real handles.
local function make_handle(): any
	local handle = { Pops = 0 }
	function handle.Pop(self: { Pops: number })
		self.Pops += 1
	end
	return handle
end

type FakeInput = { Down: { [string]: boolean }, IsDown: (self: FakeInput, action: string) -> boolean }

local function make_input(): FakeInput
	local input: FakeInput = {
		Down = {},
		IsDown = function(self: FakeInput, action: string): boolean
			return self.Down[action] == true
		end,
	}
	return input
end

return function()
	describe("Parkour InputLatch", function()
		it("blocks until released and pops attached handles once", function()
			local latch = InputLatch.new()
			local handle = make_handle()
			expect(latch:IsBlocked("Jump")).to.equal(false)

			latch:Block("Jump", { handle })
			expect(latch:IsBlocked("Jump")).to.equal(true)
			expect(handle.Pops).to.equal(0)

			latch:Release("Jump")
			latch:Release("Jump")
			expect(latch:IsBlocked("Jump")).to.equal(false)
			expect(handle.Pops).to.equal(1)
		end)

		it("keeps latches independent", function()
			local latch = InputLatch.new()
			latch:Block("Forward")
			expect(latch:IsBlocked("Forward")).to.equal(true)
			expect(latch:IsBlocked("Jump")).to.equal(false)
			latch:Release("Jump")
			expect(latch:IsBlocked("Forward")).to.equal(true)
		end)

		it("accumulates handles across repeated blocks", function()
			local latch = InputLatch.new()
			local first = make_handle()
			local second = make_handle()
			latch:Block("Jump", { first })
			latch:Block("Jump")
			latch:Block("Jump", { second })
			latch:Release("Jump")
			expect(first.Pops).to.equal(1)
			expect(second.Pops).to.equal(1)
		end)

		it("releases on Sync only the latches whose action is no longer held", function()
			local latch = InputLatch.new()
			local input = make_input()
			local handle = make_handle()
			input.Down[Actions.Jump] = true
			latch:Block("Jump", { handle })
			latch:Block("Forward")

			latch:Sync(input)
			expect(latch:IsBlocked("Jump")).to.equal(true)
			expect(latch:IsBlocked("Forward")).to.equal(false)

			input.Down[Actions.Jump] = nil
			latch:Sync(input)
			expect(latch:IsBlocked("Jump")).to.equal(false)
			expect(handle.Pops).to.equal(1)
		end)

		it("pops everything on Destroy", function()
			local latch = InputLatch.new()
			local handle = make_handle()
			latch:Block("Forward", { handle })
			latch:Destroy()
			expect(latch:IsBlocked("Forward")).to.equal(false)
			expect(handle.Pops).to.equal(1)
		end)

		it("rejects unknown latch names", function()
			local latch = InputLatch.new()
			expect(function()
				latch:Block("Crouch" :: any)
			end).to.throw()
		end)
	end)
end
