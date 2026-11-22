--!strict
-- Pure listing transforms. Each one takes the current stored value and returns a new table, or
-- nil and a reason to refuse. None mutates its input, so they are safe to re-run inside UpdateAsync.

export type Listing = {
	id: string,
	seller: number,
	itemId: string,
	qty: number,
	kind: "fixed" | "auction",
	price: number?,
	startBid: number?,
	fee: number,
	endsAt: number,
	state: "open" | "sold" | "cancelled" | "void",
	high: { userId: number, bidId: string, amount: number }?,
	buyer: { userId: number, buyId: string }?,
	voided: { [string]: boolean },
	settled: { seller: boolean },
}

export type CreateFields = {
	id: string,
	seller: number,
	itemId: string,
	qty: number,
	kind: "fixed" | "auction",
	price: number?,
	startBid: number?,
	fee: number,
	endsAt: number,
}

local Listing = {}

local function isWhole(n: any, min: number): boolean
	return type(n) == "number" and n == math.floor(n) and n >= min and n < 2 ^ 53
end

local function copy(l: Listing): Listing
	local voided = table.clone(l.voided)
	local out: Listing = {
		id = l.id,
		seller = l.seller,
		itemId = l.itemId,
		qty = l.qty,
		kind = l.kind,
		price = l.price,
		startBid = l.startBid,
		fee = l.fee,
		endsAt = l.endsAt,
		state = l.state,
		high = nil,
		buyer = nil,
		voided = voided,
		settled = { seller = l.settled.seller },
	}
	local high = l.high
	if high then
		out.high = { userId = high.userId, bidId = high.bidId, amount = high.amount }
	end
	local buyer = l.buyer
	if buyer then
		out.buyer = { userId = buyer.userId, buyId = buyer.buyId }
	end
	return out
end

function Listing.final(l: Listing, now: number): boolean
	return l.state ~= "open" or now >= l.endsAt
end

-- What the seller is owed before tax, or nil when nothing has sold. An auction stays "open" in state
-- and is decided by time, so this takes the clock: a high bid counts once the listing is final.
function Listing.saleAmount(l: Listing, now: number): number?
	if l.state == "sold" then
		return l.price
	end
	if Listing.final(l, now) and l.high then
		return l.high.amount
	end
	return nil
end

function Listing.create(current: Listing?, fields: CreateFields, now: number): (Listing?, string?)
	if current ~= nil then
		return nil, "exists"
	end
	if
		type(fields) ~= "table"
		or type(fields.id) ~= "string"
		or fields.id == ""
		or not isWhole(fields.seller, 1)
		or type(fields.itemId) ~= "string"
		or fields.itemId == ""
		or not isWhole(fields.qty, 1)
		or not isWhole(fields.fee, 0)
		or type(fields.endsAt) ~= "number"
		or fields.endsAt ~= fields.endsAt
		or fields.endsAt <= now
	then
		return nil, "bad_listing"
	end
	local price: number? = nil
	local startBid: number? = nil
	if fields.kind == "fixed" then
		if not isWhole(fields.price, 1) or fields.startBid ~= nil then
			return nil, "bad_listing"
		end
		price = fields.price
	elseif fields.kind == "auction" then
		if not isWhole(fields.startBid, 1) or fields.price ~= nil then
			return nil, "bad_listing"
		end
		startBid = fields.startBid
	else
		return nil, "bad_listing"
	end
	return {
		id = fields.id,
		seller = fields.seller,
		itemId = fields.itemId,
		qty = fields.qty,
		kind = fields.kind,
		price = price,
		startBid = startBid,
		fee = fields.fee,
		endsAt = fields.endsAt,
		state = "open",
		high = nil,
		buyer = nil,
		voided = {},
		settled = { seller = false },
	},
		nil
end

function Listing.buy(
	current: Listing?,
	buyer: number,
	buyId: string,
	price: number,
	now: number
): (Listing?, string?)
	if current == nil then
		return nil, "missing"
	end
	if current.kind ~= "fixed" then
		return nil, "not_fixed"
	end
	if current.state ~= "open" then
		return nil, "not_open"
	end
	if now >= current.endsAt then
		return nil, "ended"
	end
	if current.voided[buyId] then
		return nil, "voided"
	end
	if buyer == current.seller then
		return nil, "own_listing"
	end
	if price ~= current.price then
		return nil, "price_changed"
	end
	local out = copy(current)
	out.state = "sold"
	out.buyer = { userId = buyer, buyId = buyId }
	return out, nil
end

function Listing.bid(
	current: Listing?,
	bidder: number,
	bidId: string,
	amount: number,
	minIncrement: number,
	now: number
): (Listing?, string?)
	if current == nil then
		return nil, "missing"
	end
	if current.kind ~= "auction" then
		return nil, "not_auction"
	end
	if current.state ~= "open" then
		return nil, "not_open"
	end
	if now >= current.endsAt then
		return nil, "ended"
	end
	if not isWhole(amount, 1) then
		return nil, "bad_amount"
	end
	if current.voided[bidId] then
		return nil, "voided"
	end
	if bidder == current.seller then
		return nil, "own_listing"
	end
	local high = current.high
	if high and high.userId == bidder then
		return nil, "already_high"
	end
	local floor = if high then high.amount + minIncrement else (current.startBid or 0)
	if amount < floor then
		return nil, "too_low"
	end
	local out = copy(current)
	out.high = { userId = bidder, bidId = bidId, amount = amount }
	return out, nil
end

function Listing.cancel(current: Listing?, seller: number, now: number): (Listing?, string?)
	if current == nil then
		return nil, "missing"
	end
	if current.seller ~= seller then
		return nil, "not_yours"
	end
	if current.state ~= "open" then
		return nil, "not_open"
	end
	if now >= current.endsAt then
		return nil, "ended"
	end
	if current.high then
		return nil, "has_bids"
	end
	local out = copy(current)
	out.state = "cancelled"
	return out, nil
end

function Listing.void(current: Listing?, id: string, voidId: string): (Listing?, string?)
	if current == nil then
		local tombstone: any =
			{ id = id, state = "void", voided = { [voidId] = true }, settled = { seller = false } }
		return tombstone :: Listing, nil
	end
	local out = copy(current)
	out.voided[voidId] = true
	return out, nil
end

function Listing.markSettled(current: Listing?, side: "seller"): (Listing?, string?)
	if current == nil then
		return nil, "missing"
	end
	local out = copy(current)
	out.settled[side] = true
	return out, nil
end

return Listing
