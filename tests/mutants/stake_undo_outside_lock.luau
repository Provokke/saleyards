--!strict
-- Market buy and bid: the rollback is left until the save has returned, so a queued autosave can store the failed stake first.
return {
	name = "stake_undo_outside_lock",
	file = "src/server/Market.luau",
	find = [==[if not saveProfile(userId, profile, undo) then
			return nil, "save_failed", nil, nil]==],
	replace = [==[if not saveProfile(userId, profile) then
			undo()
			return nil, "save_failed", nil, nil]==],
}
