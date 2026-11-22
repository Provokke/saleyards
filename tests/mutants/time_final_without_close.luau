--!strict
-- Market: a listing final only by the clock is decided from a plain read.
return {
	name = "time_final_without_close",
	file = "src/server/Market.luau",
	find = [==[if settler.needsClose(claim, listing, at, userId) then]==],
	replace = [==[if false and settler.needsClose(claim, listing, at, userId) then]==],
}
