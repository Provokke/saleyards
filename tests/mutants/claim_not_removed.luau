--!strict
-- Market: applying an outcome leaves the claim in the profile.
return {
	name = "claim_not_removed",
	file = "src/server/Market.luau",
	find = [==[		profile.claims[claim.id] = nil
		if profile.notices]==],
	replace = [==[		if profile.notices]==],
}
