--!strict
-- Settle: any buy claim on a sold listing is given the item.
return {
	name = "pay_without_buyer_check",
	file = "src/server/Settle.luau",
	find = [==[		and listing.buyer.buyId == claim.id
		and listing.buyer.userId == userId
]==],
	replace = [==[]==],
}
