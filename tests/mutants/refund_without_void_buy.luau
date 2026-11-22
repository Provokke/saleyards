--!strict
-- Settle: a buy claim with no void is refunded straight away.
return {
	name = "refund_without_void_buy",
	file = "src/server/Settle.luau",
	find = [==[{ action = "give_item" }
	end
	if listing == nil or not listing.voided[claim.id] then
		return { action = "void_then_decide" }
	end
	return]==],
	replace = [==[{ action = "give_item" }
	end
	return]==],
}
