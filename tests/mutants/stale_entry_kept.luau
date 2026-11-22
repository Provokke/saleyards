--!strict
-- Market: a buy or bid refused because the listing is over leaves its browse entry in place.
return {
	name = "stale_entry_kept",
	file = "src/server/Market.luau",
	find = [==[if preReason == "not_open" or preReason == "ended" then]==],
	replace = [==[if false then]==],
}
