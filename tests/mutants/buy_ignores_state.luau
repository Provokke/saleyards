--!strict
-- Listing.buy skips the state == open check.
return {
	name = "buy_ignores_state",
	file = "src/server/Listing.luau",
	find = [==[	if current.state ~= "open" then
		return nil, "not_open"
	end
	if now >= current.endsAt then
		return nil, "ended"
	end
	if current.voided[buyId]]==],
	replace = [==[	if now >= current.endsAt then
		return nil, "ended"
	end
	if current.voided[buyId]]==],
}
