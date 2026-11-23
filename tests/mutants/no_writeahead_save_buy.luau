--!strict
-- Market: buy does not save the profile before the shared buy write.
return {
	name = "no_writeahead_save_buy",
	file = "src/server/Market.luau",
	find = [==[if not saveProfile(userId, profile, undo) then
			return nil, "save_failed", nil, nil]==],
	replace = [==[if false and not saveProfile(userId, profile, undo) then
			return nil, "save_failed", nil, nil]==],
}
