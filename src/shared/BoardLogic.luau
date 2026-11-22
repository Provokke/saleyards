--!strict
-- The market board's pure rules: time left, the next bid, what a seller receives, whether a listing
-- may be sent, and plain words for everything the server can answer. No Roblox services, so the
-- specs run it directly. Nothing here decides money: the server does, and the board only shows it.
local BoardLogic = {}

export type Items = { [string]: { name: string } }

export type Draft = {
	itemId: string?,
	qty: number?,
	kind: string,
	price: number?,
	hours: number?,
	owned: number, -- how many of the chosen item the player holds, from the last Sync
	coins: number, -- from the last Sync
}

export type Limits = {
	MinPrice: number,
	MaxPrice: number,
	MaxQty: number,
	ListingFee: number,
	ListingHours: { number },
}

-- "2h 05m", "5m 03s", "42s" or "Ended".
function BoardLogic.timeLeft(seconds: number): string
	local s = math.floor(seconds)
	if s <= 0 then
		return "Ended"
	end
	if s >= 3600 then
		return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
	end
	if s >= 60 then
		return string.format("%dm %02ds", s // 60, s % 60)
	end
	return `{s}s`
end

-- "1,250 Coins". The count is whole Coins already.
function BoardLogic.coins(amount: number): string
	local digits = tostring(math.floor(math.abs(amount)))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return (if amount < 0 then "-" else "") .. grouped .. " Coins"
end

-- The price a browse row shows and the note under it. An auction shows its high bid once it has
-- one, as of the read that cached the row, and its start bid until then.
function BoardLogic.rowPrice(kind: string, price: number?, startBid: number?, high: number?): (number, string)
	if kind ~= "auction" then
		return price or 0, "buy now"
	end
	if high ~= nil then
		return high, "high bid"
	end
	return startBid or 0, "start bid"
end

-- The least a new bid may be. `knownHigh` is a high bid this client has seen, if any: the first
-- bid only has to meet the start bid, later ones must beat the high bid by the increment.
function BoardLogic.minNextBid(startBid: number, knownHigh: number?, increment: number): number
	if knownHigh ~= nil and knownHigh > 0 then
		return math.max(startBid, knownHigh + increment)
	end
	return startBid
end

-- What the seller is paid for a sale at `price`: the price less the yards' share, rounded the same
-- way the server rounds it (the tax is floored). Shown as information only.
function BoardLogic.receiveAfterTax(price: number, saleTax: number): number
	return price - math.floor(price * saleTax)
end

-- Cancel is offered for a fixed listing, or an auction nobody has bid on. When the client cannot
-- tell whether there are bids (`hasBids` nil) it offers it and lets the server answer.
function BoardLogic.canCancel(kind: string?, hasBids: boolean?): boolean
	if kind == "auction" then
		return hasBids ~= true
	end
	return true
end

-- Why a draft listing may not be sent yet, as a short line, or nil when it is fine to send.
function BoardLogic.draftProblem(draft: Draft, limits: Limits): string?
	if draft.itemId == nil or draft.owned <= 0 then
		return "Pick an item to sell"
	end
	local qty = draft.qty
	if type(qty) ~= "number" or qty ~= math.floor(qty) or qty < 1 or qty > limits.MaxQty then
		return `Quantity must be 1 to {limits.MaxQty}`
	end
	if qty > draft.owned then
		return `You only have {draft.owned}`
	end
	local price = draft.price
	if
		type(price) ~= "number"
		or price ~= math.floor(price)
		or price < limits.MinPrice
		or price > limits.MaxPrice
	then
		return `Price must be {limits.MinPrice} to {limits.MaxPrice} Coins`
	end
	if draft.kind ~= "fixed" and draft.kind ~= "auction" then
		return "Choose fixed price or auction"
	end
	if table.find(limits.ListingHours, draft.hours) == nil then
		return "Choose how long to list for"
	end
	if draft.coins < limits.ListingFee then
		return `You need {limits.ListingFee} Coins for the listing fee`
	end
	return nil
end

-- Every answer the server gives to a refused call, in plain words. Reasons not listed here fall
-- back to a generic line, so a code never reaches the screen.
local REASONS: { [string]: string } = {
	pending = "Sent. It will finish shortly",
	busy = "Hold on, still working on your last request",
	cant_afford = "You can't afford that",
	not_enough_items = "You don't have enough of that item",
	too_low = "Someone has bid more. Raise your bid",
	already_high = "You already have the highest bid",
	own_listing = "That's your own listing",
	price_changed = "The price just changed. Have another look",
	has_bids = "This auction has bids, so it can't be cancelled",
	not_yours = "That isn't your listing",
	not_open = "That listing has closed",
	ended = "That listing has ended",
	not_ended = "That listing hasn't ended yet",
	missing = "That listing is gone",
	not_listed = "That listing is gone",
	bad_listing = "That listing is gone",
	exists = "That listing is already up",
	not_fixed = "That one is an auction. Place a bid instead",
	not_auction = "That one has a fixed price. Use Buy",
	voided = "That bid didn't go through. Try again",
	too_many_claims = "You have too many open trades. Wait for some to finish",
	save_failed = "Couldn't save. Nothing was taken, try again",
	unavailable = "The market is busy. Try again in a moment",
	no_profile = "Your data isn't ready yet",
	bad_item = "That item can't be sold",
	bad_qty = "Check the quantity",
	bad_price = "Check the price",
	bad_amount = "Check the amount",
	bad_kind = "Choose fixed price or auction",
	bad_hours = "Choose how long to list for",
}

local GENERIC = "That didn't work. Try again"

function BoardLogic.reasonText(reason: string?): string
	if reason == nil then
		return GENERIC
	end
	return REASONS[reason] or GENERIC
end

-- A line for the toast after a call. A pending result is a quiet success, a done one is short.
function BoardLogic.resultText(action: string, ok: boolean, reason: string?): string?
	if ok then
		if action == "list" then
			return "Listed on the market"
		elseif action == "buy" then
			return "Bought. It's in your items"
		elseif action == "bid" then
			return "Bid placed"
		end
		return "Listing cancelled"
	end
	return BoardLogic.reasonText(reason)
end

return BoardLogic
