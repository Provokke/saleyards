--!strict
local FakeClock = require("../fakes/FakeClock")
local FakeSortedMap = require("../fakes/FakeSortedMap")
local Faults = require("../fakes/Faults")
local Index = require("../../src/server/Index")

local function listing(id: string, price: number?, startBid: number?, endsAt: number): any
	return {
		id = id,
		itemId = "hay_bale",
		qty = 1,
		kind = if price then "fixed" else "auction",
		price = price,
		startBid = startBid,
		endsAt = endsAt,
		seller = 1,
	}
end

local function rig(): any
	local clock = FakeClock.new(0)
	local faults = Faults.new()
	local byPrice = FakeSortedMap.new(clock)
	local byEnding = FakeSortedMap.new(clock)
	local logs: { string } = {}
	local index = Index.new(byPrice:handle(faults), byEnding:handle(faults), function()
		return clock:now()
	end, function(line: string)
		table.insert(logs, line)
	end)
	return { clock = clock, faults = faults, index = index, logs = logs }
end

local function ids(page: any): string
	local out = {}
	for _, entry in page.entries do
		table.insert(out, entry.id)
	end
	return table.concat(out, ",")
end

local function filled(): any
	local r = rig()
	r.index:add(listing("a", 30, nil, 500))
	r.index:add(listing("b", nil, 10, 300))
	r.index:add(listing("c", 20, nil, 900))
	return r
end

return {
	{
		name = "index pages by price and by ending, following nextAfter",
		run = function()
			local r = filled()
			assert(ids(r.index:page("price", nil, 10)) == "b,c,a")
			assert(ids(r.index:page("ending", nil, 10)) == "b,a,c")
			local first = r.index:page("price", nil, 2)
			assert(ids(first) == "b,c" and first.nextAfter ~= nil)
			local second = r.index:page("price", first.nextAfter, 2)
			assert(ids(second) == "a" and second.nextAfter == nil)
		end,
	},
	{
		name = "index entry expires at its endsAt and remove drops it",
		run = function()
			local r = filled()
			r.clock:advance(400)
			assert(ids(r.index:page("ending", nil, 10)) == "a,c")
			r.index:remove("a")
			assert(ids(r.index:page("ending", nil, 10)) == "c")
			assert(ids(r.index:page("price", nil, 10)) == "c")
		end,
	},
	{
		name = "index failure is logged and never raised",
		run = function()
			local r = rig()
			r.faults.dead = true
			r.index:add(listing("a", 30, nil, 500))
			r.index:remove("a")
			local page = r.index:page("price", nil, 5)
			assert(#page.entries == 0 and page.nextAfter == nil)
			assert(#r.logs == 4, #r.logs)
		end,
	},
}
