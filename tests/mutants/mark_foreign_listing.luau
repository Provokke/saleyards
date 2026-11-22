--!strict
-- Market: settling marks a listing as settled even when it belongs to another player.
return {
	name = "mark_foreign_listing",
	file = "src/server/Market.luau",
	find = [==[and (listing == nil or listing.seller == nil or listing.seller == userId)]==],
	replace = [==[and true]==],
}
