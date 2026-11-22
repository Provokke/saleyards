--!strict
-- Market: a buy or bid re-settles every claim the player holds, not only its own.
return {
	name = "settle_all_after_call",
	file = "src/server/Market.luau",
	find = [==[local _, actions = settleClaims(userId, claimId)]==],
	replace = [==[local _, actions = settleClaims(userId)]==],
}
