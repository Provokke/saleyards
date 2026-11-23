--!strict
-- Market: list does not save the profile before the shared create.
return {
	name = "no_writeahead_save_list",
	file = "src/server/Market.luau",
	find = [==[if not saveProfile(userId, profile, undo) then
				return nil, "save_failed"]==],
	replace = [==[if false and not saveProfile(userId, profile, undo) then
				return nil, "save_failed"]==],
}
