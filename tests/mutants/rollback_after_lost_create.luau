--!strict
-- Market: a lost create rolls the stake back.
return {
	name = "rollback_after_lost_create",
	file = "src/server/Market.luau",
	find = [==[			-- Raised or refused: the claim stays]==],
	replace = [==[			if not ok then
				profile.items[itemId] = (profile.items[itemId] or 0) + qty
				profile.coins += fee
				profile.claims[listingId] = nil
				saveProfile(userId)
				return nil, "rolled_back"
			end
			-- Raised or refused: the claim stays]==],
}
