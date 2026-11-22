--!strict
local FakeClock = require("../fakes/FakeClock")
local FakeSortedMap = require("../fakes/FakeSortedMap")

local function keys(items: { FakeSortedMap.Item }): string
	local out = {}
	for _, item in items do
		table.insert(out, item.key)
	end
	return table.concat(out, ",")
end

local function filled(): FakeSortedMap.FakeSortedMap
	local map = FakeSortedMap.new(FakeClock.new(0))
	map:SetAsync("c", "vc", 100, 2)
	map:SetAsync("a", "va", 100, 3)
	map:SetAsync("b", "vb", 100, 2)
	map:SetAsync("d", "vd", 100, 1)
	return map
end

return {
	{
		name = "orders by sortKey then key, in both directions, and honours count",
		run = function()
			local map = filled()
			assert(keys(map:GetRangeAsync("Ascending", 10)) == "d,b,c,a")
			assert(keys(map:GetRangeAsync("Descending", 10)) == "a,c,b,d")
			assert(keys(map:GetRangeAsync("Ascending", 2)) == "d,b")
			local first = map:GetRangeAsync("Ascending", 1)[1]
			assert(first.value == "vd" and first.sortKey == 1)
		end,
	},
	{
		name = "bounds are exclusive on sortKey and on the key tie-break",
		run = function()
			local map = filled()
			assert(keys(map:GetRangeAsync("Ascending", 10, { sortKey = 1 })) == "b,c,a")
			assert(keys(map:GetRangeAsync("Ascending", 10, nil, { sortKey = 3 })) == "d,b,c")
			assert(keys(map:GetRangeAsync("Ascending", 10, { sortKey = 2, key = "b" })) == "c,a")
			assert(keys(map:GetRangeAsync("Ascending", 10, nil, { sortKey = 2, key = "c" })) == "d,b")
			assert(keys(map:GetRangeAsync("Ascending", 10, { sortKey = 1 }, { sortKey = 3 })) == "b,c")
			assert(keys(map:GetRangeAsync("Descending", 10, { sortKey = 1 }, { sortKey = 3 })) == "c,b")
		end,
	},
	{
		name = "pages through 45 entries in pages of 20, 20 and 5 with no repeats",
		run = function()
			local map = FakeSortedMap.new(FakeClock.new(0))
			for i = 1, 45 do
				-- five entries share each sortKey so the key tie-break is exercised across page edges
				map:SetAsync(string.format("k%02d", i), i, 100, math.ceil(i / 5))
			end
			local sizes, seen, order = {}, {}, {}
			local lower: FakeSortedMap.Bound? = nil
			while true do
				local page = map:GetRangeAsync("Ascending", 20, lower)
				if #page == 0 then
					break
				end
				table.insert(sizes, #page)
				for _, item in page do
					assert(not seen[item.key], "repeated " .. item.key)
					seen[item.key] = true
					table.insert(order, item.value)
				end
				local last = page[#page]
				lower = { key = last.key, sortKey = last.sortKey }
			end
			assert(table.concat(sizes, ",") == "20,20,5", table.concat(sizes, ","))
			for i = 1, 45 do
				assert(order[i] == i, "out of order at " .. i)
			end
		end,
	},
	{
		name = "an entry expires expiration seconds after SetAsync and a rewrite restarts it",
		run = function()
			local clock = FakeClock.new(10)
			local map = FakeSortedMap.new(clock)
			map:SetAsync("a", 1, 30, 1)
			map:SetAsync("b", 2, 100, 2)
			clock:advance(29)
			assert(keys(map:GetRangeAsync("Ascending", 10)) == "a,b", "still live just before expiry")
			map:SetAsync("a", 1, 30, 1) -- rewritten at t=39, lives to 69
			clock:advance(1)
			assert(keys(map:GetRangeAsync("Ascending", 10)) == "a,b")
			clock:advance(29)
			assert(keys(map:GetRangeAsync("Ascending", 10)) == "b", "a expired at 69")
			clock:advance(100)
			assert(#map:GetRangeAsync("Ascending", 10) == 0)
		end,
	},
	{
		name = "RemoveAsync removes, results are copies, and bad arguments are refused",
		run = function()
			local map = FakeSortedMap.new(FakeClock.new(0))
			map:SetAsync("a", { n = 1 }, 10, 1)
			map:GetRangeAsync("Ascending", 1)[1].value.n = 99
			assert(map:GetRangeAsync("Ascending", 1)[1].value.n == 1, "a read must not alias stored data")
			map:RemoveAsync("a")
			assert(#map:GetRangeAsync("Ascending", 10) == 0)
			assert(not pcall(function()
				map:GetRangeAsync("Sideways", 10)
			end))
			assert(not pcall(function()
				map:GetRangeAsync("Ascending", 0)
			end))
			assert(not pcall(function()
				map:SetAsync("a", 1, 0, 1)
			end))
			map:SetAsync("z", 1, 10, 1)
			assert(not pcall(function()
				map:GetRangeAsync("Ascending", 10, { key = "a" })
			end))
		end,
	},
}
