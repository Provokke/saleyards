--!strict
-- Market: the per-user lock always succeeds.
return {
	name = "no_busy_lock",
	file = "src/server/Market.luau",
	find = [==[if locks[userId] then
			return nil, "busy"]==],
	replace = [==[if false then
			return nil, "busy"]==],
}
