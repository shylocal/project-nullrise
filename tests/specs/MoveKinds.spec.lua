--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Catalog = require(ReplicatedStorage.shared.weapons.Catalog)
local MoveKinds = require(ServerScriptService.server.services.MoveKinds)

local TOLERANCE = 0.1

return function()
	describe("MoveKinds", function()
		it("covers every move kind used by the catalog", function()
			for _, weapon in ipairs(Catalog.All()) do
				for _, move in pairs(weapon.Moves) do
					expect(MoveKinds[move.Kind]).to.be.ok()
				end
			end
		end)

		it("closes a light move's HitStart window and lifetime after HitStartAt + HitWindow", function()
			local move = (Catalog.Get("Fists") :: any).Moves.Light1
			local timing = MoveKinds.Light.create_timing(move, 10, TOLERANCE)

			expect(timing.HitStartOpensAt).to.be.near(10 + 0.1 - TOLERANCE)
			expect(timing.HitStartClosesAt).to.be.near(10 + 0.1 + 0.55 + TOLERANCE)
			expect(timing.ExpiresAt).to.equal(timing.HitStartClosesAt)
		end)

		it("keeps a light move's hits valid until the move expires", function()
			local move = (Catalog.Get("Fists") :: any).Moves.Light1
			local timing = MoveKinds.Light.create_timing(move, 10, TOLERANCE)
			expect(MoveKinds.Light.hit_expires_at(move, timing, 10.2, TOLERANCE)).to.equal(timing.ExpiresAt)
		end)

		it("lets a charge be released until MaxHoldTime and keeps its lifetime past the release", function()
			local move = (Catalog.Get("Katana") :: any).Moves.Heavy
			local timing = MoveKinds.Charge.create_timing(move, 10, TOLERANCE)

			expect(timing.HitStartOpensAt).to.be.near(10 + 0.15 - TOLERANCE)
			expect(timing.HitStartClosesAt).to.be.near(10 + 10 + TOLERANCE)
			expect(timing.ExpiresAt).to.be.near(timing.HitStartClosesAt + 0.55)
		end)

		it("measures a charge's hit window from its release", function()
			local move = (Catalog.Get("Katana") :: any).Moves.Heavy
			local timing = MoveKinds.Charge.create_timing(move, 10, TOLERANCE)

			expect(MoveKinds.Charge.hit_expires_at(move, timing, 12, TOLERANCE)).to.be.near(12 + 0.55 + TOLERANCE)
			-- Never past the move's own lifetime.
			expect(MoveKinds.Charge.hit_expires_at(move, timing, timing.HitStartClosesAt, TOLERANCE)).to.equal(
				timing.ExpiresAt
			)
		end)

		it("knows a charge's release only once it was held past its HitStart marker", function()
			local heavy = (Catalog.Get("Katana") :: any).Moves.Heavy
			local light = (Catalog.Get("Katana") :: any).Moves.Light1
			local marker = 10 + heavy.HitStartAt

			-- At or before the marker (plus jitter) the client may have released
			-- early and sent HitStart at the marker: the release is unknown.
			expect(MoveKinds.Charge.released_at(heavy, 10, marker, TOLERANCE)).to.equal(nil)
			expect(MoveKinds.Charge.released_at(heavy, 10, marker + TOLERANCE, TOLERANCE)).to.equal(nil)
			expect(MoveKinds.Charge.released_at(heavy, 10, 12, TOLERANCE)).to.equal(12)
			-- A light move is never held.
			expect(MoveKinds.Light.released_at(light, 10, 12, TOLERANCE)).to.equal(nil)
		end)
	end)
end
