--!strict
local Deep = require("../fakes/Deep")
local Listing = require("../../src/server/Listing")

type Listing = Listing.Listing

local SEQUENCES = 2000
local MIN = 5
local ENDS = 1000

-- Small LCG so every run is the same and a failure can be replayed from its seed.
local function rng(seed: number): (number, number) -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(lo: number, hi: number): number
		state = (state * 48271) % 2147483647
		return lo + state % (hi - lo + 1)
	end
end

local function runSequence(seed: number, kind: "fixed" | "auction")
	local roll = rng(seed)
	local fields: Listing.CreateFields = if kind == "fixed"
		then {
			id = "L",
			seller = 1,
			itemId = "hay_bale",
			qty = 2,
			kind = "fixed",
			price = 40,
			fee = 5,
			endsAt = ENDS,
		}
		else {
			id = "L",
			seller = 1,
			itemId = "fleece",
			qty = 1,
			kind = "auction",
			startBid = 20,
			fee = 5,
			endsAt = ENDS,
		}
	local created, why = Listing.create(nil, fields, 0)
	assert(created, `seed {seed}: create refused {tostring(why)}`)
	local current: Listing = created

	local terminal: string? = nil
	local lastHigh = 0
	local deadIds: { [string]: boolean } = {} -- voided before they landed

	for step = 1, roll(1, 12) do
		local action = roll(1, 4)
		local label = `seed {seed} {kind} step {step} action {action}`
		local now = roll(ENDS - 30, ENDS + 5)
		local user = roll(1, 4)
		local id = "i" .. roll(1, 6)
		local before = Deep.copy(current)
		local out: Listing?
		if action == 1 then
			out = Listing.buy(current, user, id, if roll(1, 4) == 1 then 39 else 40, now)
		elseif action == 2 then
			out = Listing.bid(current, user, id, roll(1, 80), MIN, now)
		elseif action == 3 then
			out = Listing.cancel(current, roll(1, 2), now)
		else
			out = Listing.void(current, "L", id)
			if
				out
				and not (out.buyer and out.buyer.buyId == id)
				and not (out.high and out.high.bidId == id)
			then
				deadIds[id] = true
			end
		end
		assert(Deep.equal(before, current), `{label}: input mutated`)
		if out then
			current = out
		end

		assert(not (current.buyer ~= nil and current.high ~= nil), `{label}: sale decided twice`)
		if terminal then
			assert(current.state == terminal, `{label}: state left {terminal}`)
		elseif current.state ~= "open" then
			terminal = current.state
		end
		local high = current.high
		if high then
			assert(high.amount >= lastHigh, `{label}: high bid went down`)
			lastHigh = high.amount
			assert(not deadIds[high.bidId], `{label}: voided bid id recorded`)
		end
		local buyer = current.buyer
		if buyer then
			assert(not deadIds[buyer.buyId], `{label}: voided buy id recorded`)
		end
	end
end

return {
	{
		name = "seeded random sequences keep the listing invariants",
		run = function()
			for seed = 1, SEQUENCES do
				runSequence(seed, if seed % 2 == 0 then "fixed" else "auction")
			end
		end,
	},
}
