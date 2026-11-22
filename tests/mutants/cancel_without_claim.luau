--!strict
-- Market: cancel runs its store write for any listing id, not only one the player holds a claim on.
return {
	name = "cancel_without_claim",
	file = "src/server/Market.luau",
	find = [==[if held == nil or held.kind ~= "listing" then]==],
	replace = [==[if false then]==],
}
