--!strict
local Deep = require("../fakes/Deep")
local Listing = require("../../src/server/Listing")

type Listing = Listing.Listing

local MIN = 5

local function fixedFields(): Listing.CreateFields
	return {
		id = "L1",
		seller = 1,
		itemId = "hay_bale",
		qty = 2,
		kind = "fixed",
		price = 40,
		fee = 5,
		endsAt = 1000,
	}
end

local function auctionFields(): Listing.CreateFields
	return {
		id = "A1",
		seller = 1,
		itemId = "fleece",
		qty = 1,
		kind = "auction",
		startBid = 20,
		fee = 5,
		endsAt = 1000,
	}
end

local function fixed(): Listing
	local l = Listing.create(nil, fixedFields(), 0)
	assert(l, "fixture")
	return l
end

local function auction(): Listing
	local l = Listing.create(nil, auctionFields(), 0)
	assert(l, "fixture")
	return l
end

-- Calls fn on current, checks that current was not mutated and that a second call agrees.
local function call(current: Listing?, fn: (Listing?) -> (Listing?, string?)): (Listing?, string?)
	local before = Deep.copy(current)
	local a, ra = fn(current)
	assert(Deep.equal(before, current), "input was mutated")
	local b, rb = fn(current)
	assert(Deep.equal(a, b) and ra == rb, "re-run gave a different result")
	if a ~= nil and current ~= nil then
		assert(a ~= current, "returned the same table")
	end
	return a, ra
end

local function refused(l: Listing?, reason: string, fn: (Listing?) -> (Listing?, string?))
	local out, why = call(l, fn)
	assert(out == nil and why == reason, `expected {reason}, got {tostring(why)}`)
end

local function ok(l: Listing?, fn: (Listing?) -> (Listing?, string?)): Listing
	local out, why = call(l, fn)
	assert(out, `unexpected refusal {tostring(why)}`)
	return out
end

local function buyAs(user: number, id: string, price: number, now: number): (Listing?) -> (Listing?, string?)
	return function(l: Listing?)
		return Listing.buy(l, user, id, price, now)
	end
end

local function bidAs(user: number, id: string, amount: number, now: number): (Listing?) -> (Listing?, string?)
	return function(l: Listing?)
		return Listing.bid(l, user, id, amount, MIN, now)
	end
end

local function cancelAs(user: number, now: number): (Listing?) -> (Listing?, string?)
	return function(l: Listing?)
		return Listing.cancel(l, user, now)
	end
end

local function voidAs(id: string, voidId: string): (Listing?) -> (Listing?, string?)
	return function(l: Listing?)
		return Listing.void(l, id, voidId)
	end
end

return {
	{
		name = "create builds an open listing from nil",
		run = function()
			local l = ok(nil, function(c)
				return Listing.create(c, fixedFields(), 0)
			end)
			assert(l.state == "open" and l.price == 40 and l.startBid == nil)
			assert(l.settled.seller == false and next(l.voided) == nil)
		end,
	},
	{
		name = "create refuses over a listing or a tombstone",
		run = function()
			local f = function(c: Listing?)
				return Listing.create(c, fixedFields(), 0)
			end
			refused(fixed(), "exists", f)
			local tomb = Listing.void(nil, "L1", "x")
			refused(tomb, "exists", f)
		end,
	},
	{
		name = "create refuses malformed fields",
		run = function()
			local function bad(mutate: (any) -> ())
				local fields: any = fixedFields()
				mutate(fields)
				refused(nil, "bad_listing", function(c)
					return Listing.create(c, fields, 0)
				end)
			end
			bad(function(f)
				f.qty = 0
			end)
			bad(function(f)
				f.price = 1.5
			end)
			bad(function(f)
				f.price = nil
			end)
			bad(function(f)
				f.endsAt = 0
			end)
			bad(function(f)
				f.kind = "swap"
			end)
			bad(function(f)
				f.id = ""
			end)
			bad(function(f)
				f.startBid = 5
			end)
			local a: any = auctionFields()
			a.startBid = nil
			refused(nil, "bad_listing", function(c)
				return Listing.create(c, a, 0)
			end)
		end,
	},
	{
		name = "buy sells and records buyer and buy id",
		run = function()
			local s = ok(fixed(), buyAs(2, "b1", 40, 10))
			assert(s.state == "sold")
			assert(s.buyer and s.buyer.userId == 2 and s.buyer.buyId == "b1")
		end,
	},
	{
		name = "buy refusals",
		run = function()
			refused(fixed(), "price_changed", buyAs(2, "b1", 39, 10))
			refused(fixed(), "ended", buyAs(2, "b1", 40, 1000))
			refused(fixed(), "own_listing", buyAs(1, "b1", 40, 10))
			local sold = ok(fixed(), buyAs(2, "b1", 40, 10))
			refused(sold, "not_open", buyAs(3, "b2", 40, 11))
			refused(auction(), "not_fixed", buyAs(2, "b1", 40, 10))
			local voided = ok(fixed(), voidAs("L1", "b9"))
			refused(voided, "voided", buyAs(2, "b9", 40, 10))
			refused(nil, "missing", buyAs(2, "b1", 40, 10))
		end,
	},
	{
		name = "bid enforces start bid and increment",
		run = function()
			refused(auction(), "too_low", bidAs(2, "d1", 19, 10))
			local first = ok(auction(), bidAs(2, "d1", 20, 10))
			assert(first.high and first.high.amount == 20 and first.high.bidId == "d1")
			refused(first, "too_low", bidAs(3, "d2", 24, 11))
			local second = ok(first, bidAs(3, "d2", 25, 11))
			assert(second.high and second.high.userId == 3)
			assert(first.high and first.high.userId == 2, "old listing changed")
		end,
	},
	{
		name = "bid refusals",
		run = function()
			local first = ok(auction(), bidAs(2, "d1", 20, 10))
			refused(first, "already_high", bidAs(2, "d2", 50, 11))
			refused(auction(), "own_listing", bidAs(1, "d1", 20, 10))
			refused(auction(), "ended", bidAs(2, "d1", 20, 1000))
			refused(fixed(), "not_auction", bidAs(2, "d1", 20, 10))
			refused(nil, "missing", bidAs(2, "d1", 20, 10))
			local voided = ok(auction(), voidAs("A1", "d9"))
			refused(voided, "voided", bidAs(2, "d9", 20, 10))
			local cancelled = ok(auction(), cancelAs(1, 10))
			refused(cancelled, "not_open", bidAs(2, "d1", 20, 10))
		end,
	},
	{
		name = "cancel",
		run = function()
			local c = ok(fixed(), cancelAs(1, 10))
			assert(c.state == "cancelled")
			refused(fixed(), "not_yours", cancelAs(2, 10))
			refused(fixed(), "ended", cancelAs(1, 1000))
			refused(c, "not_open", cancelAs(1, 10))
			refused(nil, "missing", cancelAs(1, 10))
			local bid = ok(auction(), bidAs(2, "d1", 20, 10))
			refused(bid, "has_bids", cancelAs(1, 11))
		end,
	},
	{
		name = "void records the id and never changes a sale or a bid",
		run = function()
			local open = ok(fixed(), voidAs("L1", "v1"))
			assert(open.state == "open" and open.voided.v1 == true)
			local sold = ok(fixed(), buyAs(2, "b1", 40, 10))
			local after = ok(sold, voidAs("L1", "b1"))
			assert(after.state == "sold" and after.buyer and after.buyer.buyId == "b1" and after.voided.b1)
			local bid = ok(auction(), bidAs(2, "d1", 20, 10))
			local afterBid = ok(bid, voidAs("A1", "d1"))
			assert(afterBid.high and afterBid.high.bidId == "d1")
			local tomb = ok(nil, voidAs("L1", "v1"))
			assert(tomb.state == "void" and tomb.id == "L1" and tomb.voided.v1 == true)
			assert(tomb.settled.seller == false)
		end,
	},
	{
		name = "markSettled sets the flag and refuses a missing key",
		run = function()
			local mark = function(l: Listing?)
				return Listing.markSettled(l, "seller")
			end
			local s = ok(fixed(), mark)
			assert(s.settled.seller == true)
			refused(nil, "missing", mark)
		end,
	},
	{
		name = "final and saleAmount in each state",
		run = function()
			local f = fixed()
			assert(Listing.final(f, 999) == false and Listing.final(f, 1000) == true)
			assert(Listing.saleAmount(f) == nil)
			local sold = ok(f, buyAs(2, "b1", 40, 10))
			assert(Listing.final(sold, 10) and Listing.saleAmount(sold) == 40)
			local c = ok(f, cancelAs(1, 10))
			assert(Listing.final(c, 10) and Listing.saleAmount(c) == nil)
			local a = ok(auction(), bidAs(2, "d1", 20, 10))
			assert(not Listing.final(a, 999) and Listing.saleAmount(a) == nil)
			assert(Listing.saleAmountAt(a, 999) == nil and Listing.saleAmountAt(a, 1000) == 20)
			assert(Listing.saleAmountAt(auction(), 1000) == nil)
			local tomb = Listing.void(nil, "x", "y")
			assert(tomb and Listing.final(tomb, 0) and Listing.saleAmount(tomb) == nil)
		end,
	},
}
