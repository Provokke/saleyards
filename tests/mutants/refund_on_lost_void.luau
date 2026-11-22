--!strict
-- Market: a lost void write is treated as a refund.
return {
	name = "refund_on_lost_void",
	file = "src/server/Market.luau",
	find = [==[			if not voidOk then
				return nil, nil, tostring(voided)]==],
	replace = [==[			if not voidOk then
				return { action = "refund", coins = claim.amount }, listing, nil]==],
}
