--!strict
-- Pure settlement decision. Given what a player staked (a claim in their profile) and the shared
-- listing record, say what to do next. It reads, never writes: Market.settle applies the outcome.

-- It takes the Listing module as an argument, like every leaf module here, so only the server
-- script wires modules together. Listing values are typed loosely for the same reason.
type Listing = any

-- The two Listing functions a decision needs.
export type ListingLib = {
	final: (listing: any, now: number) -> boolean,
	saleAmount: (listing: any, now: number) -> number?,
}

export type Claim = {
	kind: "listing" | "buy" | "bid",
	listingId: string,
	itemId: string,
	qty: number,
	-- The price paid (buy), the Coins held (bid), or the asking price or start bid (listing).
	amount: number,
	fee: number?,
	-- The buyId or bidId; for a listing claim it is the listingId.
	id: string,
	at: number,
}

export type Outcome = {
	action: "keep" | "void_then_decide" | "pay" | "return_item" | "give_item" | "refund",
	coins: number?,
	refundFee: boolean?,
}

local Settle = {}

local function decideListing(Listing: ListingLib, listing: Listing?, now: number, saleTax: number): Outcome
	if listing == nil then
		return { action = "void_then_decide" }
	end
	if listing.state == "void" then
		return { action = "return_item", refundFee = true }
	end
	if not Listing.final(listing, now) then
		return { action = "keep" }
	end
	local sale = Listing.saleAmount(listing, now)
	if sale ~= nil then
		return { action = "pay", coins = sale - math.floor(sale * saleTax) }
	end
	return { action = "return_item", refundFee = false }
end

local function decideBuy(claim: Claim, listing: Listing?): Outcome
	if listing ~= nil and listing.buyer ~= nil and listing.buyer.buyId == claim.id then
		return { action = "give_item" }
	end
	if listing == nil or not listing.voided[claim.id] then
		return { action = "void_then_decide" }
	end
	return { action = "refund", coins = claim.amount }
end

local function decideBid(Listing: ListingLib, claim: Claim, listing: Listing?, now: number): Outcome
	if listing ~= nil then
		local high = listing.high
		if high ~= nil and high.bidId == claim.id then
			if Listing.final(listing, now) then
				return { action = "give_item" }
			end
			return { action = "keep" }
		end
	end
	if listing == nil or not listing.voided[claim.id] then
		return { action = "void_then_decide" }
	end
	return { action = "refund", coins = claim.amount }
end

export type Settler = {
	decide: (claim: Claim, listing: Listing?, now: number, saleTax: number) -> Outcome,
}

function Settle.new(Listing: ListingLib): Settler
	return {
		decide = function(claim: Claim, listing: Listing?, now: number, saleTax: number): Outcome
			if claim.kind == "listing" then
				return decideListing(Listing, listing, now, saleTax)
			elseif claim.kind == "buy" then
				return decideBuy(claim, listing)
			end
			return decideBid(Listing, claim, listing, now)
		end,
	}
end

return Settle
