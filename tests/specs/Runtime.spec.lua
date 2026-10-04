--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestService = game:GetService("TestService")

local Runtime = require(ReplicatedStorage.shared.runtime.Runtime)
local Deps = require(ReplicatedStorage.shared.runtime.Deps)
local FakeClock = require(TestService.support.FakeClock)

type ServiceOptions = { FailStart: boolean?, FailDestroy: boolean? }

local function make_service(log: { string }, name: string, opts: ServiceOptions?)
	local options: ServiceOptions = opts or {}
	local service = {}

	function service.Start(_self: any)
		table.insert(log, "start:" .. name)
		if options.FailStart then
			error("start failed", 0)
		end
	end

	function service.Destroy(_self: any)
		table.insert(log, "destroy:" .. name)
		if options.FailDestroy then
			error("destroy failed", 0)
		end
	end

	return service
end

return function()
	describe("Runtime", function()
		it("builds in Add order, then starts in Add order", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				table.insert(log, "build:A")
				return make_service(log, "A")
			end)
			rt:Add("B", function(get)
				table.insert(log, "build:B")
				expect(get("A")).to.be.ok()
				return make_service(log, "B")
			end)

			rt:Start()

			expect(table.concat(log, ",")).to.equal("build:A,build:B,start:A,start:B")
			expect(rt:Get("B")).to.be.ok()
			rt:Destroy()
		end)

		it("destroys in reverse Add order and only once", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				return make_service(log, "A")
			end)
			rt:Add("B", function()
				return make_service(log, "B")
			end)
			rt:Add("C", function()
				return make_service(log, "C")
			end)
			rt:Start()
			table.clear(log)

			rt:Destroy()
			rt:Destroy()

			expect(table.concat(log, ",")).to.equal("destroy:C,destroy:B,destroy:A")
		end)

		it("keeps destroying when one Destroy fails", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				return make_service(log, "A")
			end)
			rt:Add("B", function()
				return make_service(log, "B", { FailDestroy = true })
			end)
			rt:Start()
			table.clear(log)

			rt:Destroy()

			expect(table.concat(log, ",")).to.equal("destroy:B,destroy:A")
		end)

		it("rolls back built services when a factory fails", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				return make_service(log, "A")
			end)
			rt:Add("B", function()
				return make_service(log, "B")
			end)
			rt:Add("C", function(): any
				error("boom", 0)
			end)

			local ok, err = pcall(function()
				rt:Start()
			end)

			expect(ok).to.equal(false)
			expect(tostring(err)).to.equal("Spec: failed to start C: boom")
			expect(table.concat(log, ",")).to.equal("destroy:B,destroy:A")
		end)

		it("rolls back every built service when a Start fails", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				return make_service(log, "A")
			end)
			rt:Add("B", function()
				return make_service(log, "B", { FailStart = true })
			end)

			local ok, err = pcall(function()
				rt:Start()
			end)

			expect(ok).to.equal(false)
			expect(tostring(err)).to.equal("Spec: failed to start B: start failed")
			expect(table.concat(log, ",")).to.equal("start:A,start:B,destroy:B,destroy:A")
		end)

		it("rejects a get for a service that is not built yet", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function(get)
				get("B")
				return make_service(log, "A")
			end)
			rt:Add("B", function()
				return make_service(log, "B")
			end)

			local ok, err = pcall(function()
				rt:Start()
			end)

			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "failed to start A", 1, true) ~= nil).to.equal(true)
			expect(#log).to.equal(0)
		end)

		it("rejects a factory result without Destroy", function()
			local rt = Runtime.new("Spec")
			rt:Add("A", function(): any
				return {}
			end)

			expect(function()
				rt:Start()
			end).to.throw()
		end)

		it("rejects duplicate names, Add after Start and unknown Get", function()
			local log = {}
			local rt = Runtime.new("Spec")
			rt:Add("A", function()
				return make_service(log, "A")
			end)

			expect(function()
				rt:Add("A", function()
					return make_service(log, "A")
				end)
			end).to.throw()

			rt:Start()

			expect(function()
				rt:Add("B", function()
					return make_service(log, "B")
				end)
			end).to.throw()
			expect(function()
				rt:Get("Missing")
			end).to.throw()

			rt:Destroy()
		end)
	end)

	describe("Deps.check", function()
		it("names the owner and the first missing dependency", function()
			local ok, err = pcall(function()
				Deps.check({ a = 1 }, "Thing", { "a", "b", "c" })
			end)

			expect(ok).to.equal(false)
			expect(string.find(tostring(err), "Thing.new: missing dependency 'b'", 1, true) ~= nil).to.equal(true)
		end)

		it("accepts false as a present dependency and rejects non-tables", function()
			expect(function()
				Deps.check({ flag = false }, "Thing", { "flag" })
			end).never.to.throw()
			expect(function()
				Deps.check(nil, "Thing", {})
			end).to.throw()
		end)
	end)

	describe("FakeClock", function()
		it("runs due callbacks in due order with now set to each due time", function()
			local clock = FakeClock.new(10)
			local seen = {}

			clock.after(0.5, function()
				table.insert(seen, ("b@%.2f"):format(clock.now()))
			end)
			clock.after(0.25, function()
				table.insert(seen, ("a@%.2f"):format(clock.now()))
				clock.after(0.1, function()
					table.insert(seen, ("nested@%.2f"):format(clock.now()))
				end)
			end)

			clock:advance(1)

			expect(table.concat(seen, ",")).to.equal("a@10.25,nested@10.35,b@10.50")
			expect(clock.now()).to.equal(11)
			expect(clock:pending()).to.equal(0)
		end)

		it("does not run cancelled or future callbacks", function()
			local clock = FakeClock.new()
			local ran = 0
			local cancel = clock.after(1, function()
				ran += 1
			end)
			clock.after(5, function()
				ran += 10
			end)

			cancel()
			clock:advance(2)

			expect(ran).to.equal(0)
			expect(clock:pending()).to.equal(1)
		end)
	end)
end
