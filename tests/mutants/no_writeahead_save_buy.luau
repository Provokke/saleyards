--!strict
-- Market: buy does not save the profile before the shared buy write.
return {
	name = "no_writeahead_save_buy",
	file = "src/server/Market.luau",
	find = [==[if not saveProfile(userId) then
			profile.coins += amount]==],
	replace = [==[if false and not saveProfile(userId) then
			profile.coins += amount]==],
}
