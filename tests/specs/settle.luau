--!strict
local Listing = require("../../src/server/Listing")
local Settle = require("../../src/server/Settle")

type Listing = Listing.Listing
type Claim = Settle.Claim

local TAX = 0.1
local MIN = 5

local function must(l: Listing?, reason: string?): Listing
	assert(l, reason or "transform refused")
	return l
end

local function fixed(price: number): Listing
	return must(Listing.create(nil, {
		id = "L1",
		seller = 1,
		itemId = "hay_bale",
		qty = 2,
		kind = "fixed",
		price = price,
		fee = 5,
		endsAt = 1000,
	}, 0))
end

local function auction(): Listing
	return must(Listing.create(nil, {
		id = "A1",
		seller = 1,
		itemId = "fleece",
		qty = 1,
		kind = "auction",
		startBid = 20,
		fee = 5,
		endsAt = 1000,
	}, 0))
end

local function sold(price: number): Listing
	return must(Listing.buy(fixed(price), 2, "b1", price, 10))
end

local function cancelled(): Listing
	return must(Listing.cancel(fixed(40), 1, 10))
end

local function bidded(id: string, amount: number): Listing
	return must(Listing.bid(auction(), 2, id, amount, MIN, 10))
end

local function tombstone(voidId: string): Listing
	return must(Listing.void(nil, "L1", voidId))
end

local function listingClaim(id: string): Claim
	return {
		kind = "listing",
		listingId = id,
		itemId = "hay_bale",
		qty = 2,
		amount = 40,
		fee = 5,
		id = id,
		at = 0,
	}
end

local function buyClaim(id: string): Claim
	return {
		kind = "buy",
		listingId = "L1",
		itemId = "hay_bale",
		qty = 2,
		amount = 40,
		id = id,
		at = 0,
	}
end

local function bidClaim(id: string, amount: number): Claim
	return {
		kind = "bid",
		listingId = "A1",
		itemId = "fleece",
		qty = 1,
		amount = amount,
		id = id,
		at = 0,
	}
end

local function decide(c: Claim, l: Listing?, now: number): Settle.Outcome
	return Settle.decide(c, l, now, TAX)
end

-- Applies the void the outcome asked for, as the caller would, and returns the listing it left.
local function applyVoid(c: Claim, l: Listing?): Listing
	return must(Listing.void(l, c.listingId, c.id))
end

return {
	{
		name = "listing claim: missing listing voids first, then returns item and fee",
		run = function()
			local c = listingClaim("L1")
			assert(decide(c, nil, 5).action == "void_then_decide")
			local o = decide(c, applyVoid(c, nil), 5)
			assert(o.action == "return_item" and o.refundFee == true)
		end,
	},
	{
		name = "listing claim: open and not final keeps",
		run = function()
			assert(decide(listingClaim("L1"), fixed(40), 999).action == "keep")
			assert(decide(listingClaim("A1"), bidded("d1", 20), 999).action == "keep")
		end,
	},
	{
		name = "listing claim: sold pays sale less floored tax",
		run = function()
			local o = decide(listingClaim("L1"), sold(40), 10)
			assert(o.action == "pay" and o.coins == 36)
			local small = decide(listingClaim("L1"), sold(9), 10)
			assert(small.action == "pay" and small.coins == 9)
		end,
	},
	{
		name = "listing claim: ended auction with a high bid pays",
		run = function()
			local o = decide(listingClaim("A1"), bidded("d1", 50), 1000)
			assert(o.action == "pay" and o.coins == 45)
		end,
	},
	{
		name = "listing claim: cancelled or ended unsold returns the item, fee kept",
		run = function()
			local a = decide(listingClaim("L1"), cancelled(), 10)
			assert(a.action == "return_item" and a.refundFee == false)
			local b = decide(listingClaim("A1"), auction(), 1000)
			assert(b.action == "return_item" and b.refundFee == false)
			local c = decide(listingClaim("L1"), fixed(40), 1000)
			assert(c.action == "return_item" and c.refundFee == false)
		end,
	},
	{
		name = "buy claim: a buy that landed gives the item straight away",
		run = function()
			assert(decide(buyClaim("b1"), sold(40), 10).action == "give_item")
		end,
	},
	{
		name = "buy claim: a buy that never landed voids, then refunds",
		run = function()
			local c = buyClaim("b9")
			local l = sold(40)
			assert(decide(c, l, 10).action == "void_then_decide")
			local o = decide(c, applyVoid(c, l), 10)
			assert(o.action == "refund" and o.coins == 40)
			assert(decide(c, fixed(40), 10).action == "void_then_decide")
			assert(decide(c, nil, 10).action == "void_then_decide")
		end,
	},
	{
		name = "buy claim: on a void tombstone, voided and not mine refunds",
		run = function()
			local c = buyClaim("b9")
			local tomb = tombstone("other")
			assert(decide(c, tomb, 10).action == "void_then_decide")
			local o = decide(c, applyVoid(c, tomb), 10)
			assert(o.action == "refund" and o.coins == 40)
			assert(decide(buyClaim("other"), tomb, 10).action == "refund")
		end,
	},
	{
		name = "bid claim: the winner after the end gets the item",
		run = function()
			assert(decide(bidClaim("d1", 50), bidded("d1", 50), 1000).action == "give_item")
		end,
	},
	{
		name = "bid claim: winning while still open keeps",
		run = function()
			assert(decide(bidClaim("d1", 50), bidded("d1", 50), 999).action == "keep")
		end,
	},
	{
		name = "bid claim: an outbid bid voids, then refunds",
		run = function()
			local c = bidClaim("d1", 50)
			local l = must(Listing.bid(bidded("d1", 50), 3, "d2", 60, MIN, 20))
			assert(decide(c, l, 30).action == "void_then_decide")
			local o = decide(c, applyVoid(c, l), 30)
			assert(o.action == "refund" and o.coins == 50)
			assert(decide(c, nil, 30).action == "void_then_decide")
		end,
	},
	{
		name = "bid claim: a win after the end gives the item even if its id was voided",
		run = function()
			local c = bidClaim("d1", 50)
			local l = applyVoid(c, bidded("d1", 50))
			assert(decide(c, l, 1000).action == "give_item")
		end,
	},
	{
		name = "bid claim: a bid that never landed voids, then refunds",
		run = function()
			local c = bidClaim("d7", 50)
			local l = bidded("d1", 30)
			assert(decide(c, l, 10).action == "void_then_decide")
			assert(decide(c, applyVoid(c, l), 10).action == "refund")
			assert(decide(c, applyVoid(c, auction()), 1000).action == "refund")
		end,
	},
	{
		name = "termination: after one void the outcome is never void_then_decide",
		run = function()
			local listings: { Listing? } = {
				nil,
				fixed(40),
				sold(40),
				cancelled(),
				auction(),
				bidded("d1", 50),
				tombstone("x"),
			}
			local claims: { Claim } = {
				listingClaim("L1"),
				buyClaim("b1"),
				buyClaim("zz"),
				bidClaim("d1", 50),
				bidClaim("zz", 50),
			}
			local checked = 0
			for _, l in listings do
				for _, now in { 10, 999, 1000 } do
					for _, c in claims do
						if decide(c, l, now).action == "void_then_decide" then
							local again = decide(c, applyVoid(c, l), now)
							assert(again.action ~= "void_then_decide", "loops after one void")
							checked += 1
						end
					end
				end
			end
			assert(checked > 0)
		end,
	},
}
