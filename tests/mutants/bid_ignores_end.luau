--!strict
-- Listing.bid skips the endsAt check.
return {
	name = "bid_ignores_end",
	file = "src/server/Listing.luau",
	find = [==[	if now >= current.endsAt then
		return nil, "ended"
	end
	if not isWhole(amount, 1)]==],
	replace = [==[	if not isWhole(amount, 1)]==],
}
