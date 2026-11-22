--!strict
-- In-memory stand-in for a MemoryStoreSortedMap: SetAsync, RemoveAsync and GetRangeAsync.
-- Entries are ordered by sortKey and then by key, bounds are exclusive, and an entry expires
-- `expiration` seconds after the SetAsync that wrote it, read off the FakeClock.
local Deep = require("./Deep")
local FakeClock = require("./FakeClock")
local Faults = require("./Faults")

local FakeSortedMap = {}
FakeSortedMap.__index = FakeSortedMap

type Entry = { value: any, sortKey: number, expiresAt: number }

export type Bound = { key: string?, sortKey: number? }
export type Item = { key: string, value: any, sortKey: number }

export type FakeSortedMap = typeof(setmetatable(
	{} :: {
		clock: FakeClock.FakeClock,
		entries: { [string]: Entry },
	},
	FakeSortedMap
))

export type Handle = {
	SetAsync: (self: Handle, key: string, value: any, expiration: number, sortKey: number) -> boolean,
	RemoveAsync: (self: Handle, key: string) -> (),
	GetRangeAsync: (self: Handle, direction: any, count: number, lower: Bound?, upper: Bound?) -> { Item },
}

function FakeSortedMap.new(clock: FakeClock.FakeClock?): FakeSortedMap
	return setmetatable({ clock = clock or FakeClock.new(), entries = {} }, FakeSortedMap)
end

function FakeSortedMap.SetAsync(
	self: FakeSortedMap,
	key: string,
	value: any,
	expiration: number,
	sortKey: number
): boolean
	assert(type(key) == "string" and key ~= "", "key must be a non-empty string")
	assert(type(expiration) == "number" and expiration > 0, "expiration must be positive")
	assert(type(sortKey) == "number" and sortKey == sortKey, "sortKey must be a number")
	self.entries[key] = {
		value = Deep.copy(value),
		sortKey = sortKey,
		expiresAt = self.clock:now() + expiration,
	}
	return true
end

function FakeSortedMap.RemoveAsync(self: FakeSortedMap, key: string)
	self.entries[key] = nil
end

-- -1, 0 or 1: where an entry sits against a bound. A bound compares the sortKey first and the key
-- only when it names one; a bound with only a key is refused, because that is not a position in
-- a sortKey ordering.
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

function FakeSortedMap.GetRangeAsync(
	self: FakeSortedMap,
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
	local now = self.clock:now()
	local found: { Item } = {}
	for key, entry in self.entries do
		if now >= entry.expiresAt then
			continue
		end
		if lower and against(entry.sortKey, key, lower) <= 0 then
			continue
		end
		if upper and against(entry.sortKey, key, upper) >= 0 then
			continue
		end
		table.insert(found, { key = key, value = Deep.copy(entry.value), sortKey = entry.sortKey })
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

-- One simulated server's view of the map. SetAsync and RemoveAsync count as writes on `faults`,
-- the same counter its DataStore handles use; reads only check that the server is alive.
function FakeSortedMap.handle(self: FakeSortedMap, faults: Faults.Faults): Handle
	local handle = {}
	function handle.SetAsync(_: any, key: string, value: any, expiration: number, sortKey: number): boolean
		local mode = faults:beforeWrite()
		local result = self:SetAsync(key, value, expiration, sortKey)
		if mode == "lost" then
			Faults.lose()
		end
		return result
	end
	function handle.RemoveAsync(_: any, key: string)
		local mode = faults:beforeWrite()
		self:RemoveAsync(key)
		if mode == "lost" then
			Faults.lose()
		end
	end
	function handle.GetRangeAsync(
		_: any,
		direction: any,
		count: number,
		lower: Bound?,
		upper: Bound?
	): { Item }
		faults:beforeRead()
		return self:GetRangeAsync(direction, count, lower, upper)
	end
	return handle :: Handle
end

return FakeSortedMap
