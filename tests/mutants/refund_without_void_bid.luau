--!strict
-- Settle: a bid claim with no void is refunded straight away.
return {
	name = "refund_without_void_bid",
	file = "src/server/Settle.luau",
	find = [==[		end
	end
	if listing == nil or not listing.voided[claim.id] then
		return { action = "void_then_decide" }
	end
	return]==],
	replace = [==[		end
	end
	return]==],
}
