--!strict
-- Market: a buy or bid stakes into its profile even when the player has left and rejoined during the pre-read.
return {
	name = "stake_into_dead_session",
	file = "src/server/Market.luau",
	find = [==[if profiles.get(userId) ~= profile then]==],
	replace = [==[if false then]==],
}
