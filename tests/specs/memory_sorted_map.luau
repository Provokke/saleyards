--!strict
local MemorySortedMap = require("../../src/server/Data/MemorySortedMap")

local function clock(): (() -> number, (number) -> ())
	local t = 1000
	return function(): number
		return t
	end, function(n: number)
		t += n
	end
end

return {
	{
		name = "a range is ordered by sortKey then key, in either direction, and capped at count",
		run = function()
			local now = clock()
			local map = MemorySortedMap.new(now)
			map:SetAsync("b", { n = 2 }, 60, 20)
			map:SetAsync("a", { n = 1 }, 60, 20)
			map:SetAsync("c", { n = 3 }, 60, 10)
			local up = map:GetRangeAsync("Ascending", 10)
			assert(up[1].key == "c" and up[2].key == "a" and up[3].key == "b", "ascending order")
			local down = map:GetRangeAsync("Enum.SortDirection.Descending", 2)
			assert(#down == 2 and down[1].key == "b" and down[2].key == "a", "descending, capped")
		end,
	},
	{
		name = "bounds are exclusive, so a page cursor never repeats its last entry",
		run = function()
			local now = clock()
			local map = MemorySortedMap.new(now)
			map:SetAsync("a", 1, 60, 10)
			map:SetAsync("b", 2, 60, 10)
			map:SetAsync("c", 3, 60, 20)
			local after = map:GetRangeAsync("Ascending", 10, { key = "a", sortKey = 10 })
			assert(#after == 2 and after[1].key == "b" and after[2].key == "c", "after the cursor")
			local ok = pcall(function()
				map:GetRangeAsync("Ascending", 10, { key = "a" })
			end)
			assert(not ok, "a bound with no sortKey is refused")
		end,
	},
	{
		name = "values are copied in and out, removed entries are gone and old entries expire",
		run = function()
			local now, advance = clock()
			local map = MemorySortedMap.new(now)
			local value = { n = 1 }
			map:SetAsync("a", value, 30, 5)
			value.n = 99
			local got = map:GetRangeAsync("Ascending", 1)[1].value
			assert(got.n == 1, "stored a copy")
			got.n = 50
			assert(map:GetRangeAsync("Ascending", 1)[1].value.n == 1, "returned a copy")
			map:SetAsync("b", 2, 60, 6)
			map:RemoveAsync("b")
			advance(30)
			assert(#map:GetRangeAsync("Ascending", 10) == 0, "a removed, and a expired")
		end,
	},
}
