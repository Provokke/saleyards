--!strict
-- In-memory stand-in for a MemoryStoreSortedMap, used in Studio alongside the in-memory data
-- stores. An unpublished place can't reach MemoryStoreService at all, so without this the
-- browse cache would stop the server starting. Entries are ordered by sortKey and then by key,
-- range bounds are exclusive, and an entry expires `expiration` seconds after it was written.
local MemorySortedMap = {}
MemorySortedMap.__index = MemorySortedMap

type Entry = { value: any, sortKey: number, expiresAt: number }
export type Bound = { key: string?, sortKey: number? }
export type Item = { key: string, value: any, sortKey: number }

export type MemorySortedMap = typeof(setmetatable(
	{} :: { clock: () -> number, entries: { [string]: Entry } },
	MemorySortedMap
))

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

function MemorySortedMap.new(clock: () -> number): MemorySortedMap
	return setmetatable({ clock = clock, entries = {} }, MemorySortedMap)
end

function MemorySortedMap.SetAsync(
	self: MemorySortedMap,
	key: string,
	value: any,
	expiration: number,
	sortKey: number
): boolean
	assert(type(key) == "string" and key ~= "", "key must be a non-empty string")
	assert(type(expiration) == "number" and expiration > 0, "expiration must be positive")
	assert(type(sortKey) == "number" and sortKey == sortKey, "sortKey must be a number")
	self.entries[key] = { value = deepCopy(value), sortKey = sortKey, expiresAt = self.clock() + expiration }
	return true
end

function MemorySortedMap.RemoveAsync(self: MemorySortedMap, key: string)
	self.entries[key] = nil
end

-- -1, 0 or 1: where an entry sits against a bound. The sortKey is compared first, and the key
-- only when the bound names one.
local function against(sortKey: number, key: string, bound: Bound): number
	local boundSort = bound.sortKey
	if boundSort == nil then
		error("a range bound needs a sortKey")
	end
	if sortKey ~= boundSort then
		return if sortKey < boundSort then -1 else 1
	end
	local boundKey = bound.key
	if boundKey == nil or key == boundKey then
		return 0
	end
	return if key < boundKey then -1 else 1
end

function MemorySortedMap.GetRangeAsync(
	self: MemorySortedMap,
	direction: any,
	count: number,
	lower: Bound?,
	upper: Bound?
): { Item }
	local name = tostring(direction)
	local descending
	if name == "Descending" or string.match(name, "%.Descending$") then
		descending = true
	elseif name == "Ascending" or string.match(name, "%.Ascending$") then
		descending = false
	else
		error("direction must be Ascending or Descending, got " .. name)
	end
	assert(
		type(count) == "number" and count == math.floor(count) and count >= 1 and count <= 200,
		"count must be a whole number from 1 to 200"
	)
	local now = self.clock()
	local found: { Item } = {}
	for key, entry in self.entries do
		if now >= entry.expiresAt then
			self.entries[key] = nil
			continue
		end
		if lower and against(entry.sortKey, key, lower) <= 0 then
			continue
		end
		if upper and against(entry.sortKey, key, upper) >= 0 then
			continue
		end
		table.insert(found, { key = key, value = deepCopy(entry.value), sortKey = entry.sortKey })
	end
	table.sort(found, function(a: Item, b: Item)
		if a.sortKey ~= b.sortKey then
			return if descending then a.sortKey > b.sortKey else a.sortKey < b.sortKey
		end
		return if descending then a.key > b.key else a.key < b.key
	end)
	while #found > count do
		table.remove(found)
	end
	return found
end

return MemorySortedMap
