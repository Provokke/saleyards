--!strict
-- The server script uses the real MemoryStore for the browse cache even in Studio with the
-- in-memory data stores, so an unpublished place stops at startup.
return {
	name = "studio_index_needs_publish",
	file = "src/server/init.server.luau",
	find = [==[if useRealStore then
	byPrice = MemoryStoreService]==],
	replace = [==[if true then
	byPrice = MemoryStoreService]==],
}
