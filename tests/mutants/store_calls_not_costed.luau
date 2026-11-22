--!strict
-- Handlers: market calls are not charged to the store limiter.
return {
	name = "store_calls_not_costed",
	file = "src/server/Handlers.luau",
	find = [==[if cost ~= nil and not deps.storeLimiter:take(userId, cost) then]==],
	replace = [==[if false then]==],
}
