--!strict
-- What a client can and can't make the server do.
local Config = require("../../src/shared/Config")
local FakeClock = require("../fakes/FakeClock")
local Handlers = require("../../src/server/Handlers")
local RateLimiter = require("../../src/shared/RateLimiter")
local Validate = require("../../src/shared/Validate")

type Rig = {
	handlers: any,
	calls: { string },
	syncs: { any },
	logs: { string },
	pages: { string },
	clock: any,
	state: { throws: boolean, busy: boolean, answer: any },
}

local function describe(name: string, ...: any): string
	local parts = { name }
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	return table.concat(parts, " ")
end

-- A market that records what it was asked and answers from `state`. User 99 has no session.
local function rig(burst: number?): Rig
	local clock = FakeClock.new(0)
	local r: Rig = {
		handlers = nil,
		calls = {},
		syncs = {},
		logs = {},
		pages = {},
		clock = clock,
		state = { throws = false, busy = false, answer = true },
	}
	local function answer(name: string): (...any) -> (any, any)
		return function(_self: any, ...: any)
			if r.state.throws then
				error("market broke")
			end
			table.insert(r.calls, describe(name, ...))
			if r.state.busy then
				return nil, "busy"
			end
			if r.state.answer == true then
				return if name == "list" then "L1" else true, nil
			end
			return nil, r.state.answer
		end
	end
	local market = {
		list = answer("list"),
		buy = answer("buy"),
		bid = answer("bid"),
		cancel = answer("cancel"),
		busy = function(): boolean
			return false
		end,
	}
	r.handlers = Handlers.new({
		validate = Validate,
		limiter = RateLimiter.new(burst or 100, 1, function()
			return clock:now()
		end),
		storeLimiter = RateLimiter.new(
			Config.Limits.StoreBurstPerPlayer,
			Config.Limits.StoreOpsPerMinute / 60,
			function()
				return clock:now()
			end
		),
		storeCost = Config.Limits.StoreCost,
		config = Config,
		market = market,
		index = {
			page = function(_self: any, sort: string, after: any, count: number): any
				local cursor = if after ~= nil then `{after.key}/{after.sortKey}` else "-"
				table.insert(r.pages, `{sort} {cursor} {count}`)
				return { entries = {}, nextAfter = nil }
			end,
		},
		allowed = function(userId: number): boolean
			return userId ~= 99
		end,
		sync = function(userId: number, result: any)
			table.insert(r.syncs, { userId = userId, result = result })
		end,
		log = function(message: string)
			table.insert(r.logs, message)
		end,
	})
	return r
end

local function dropped(r: Rig, ...: any)
	local before = r.handlers.dropped
	r.handlers:handle(1, ...)
	assert(#r.calls == 0, `a market call went through: {r.calls[1]}`)
	assert(#r.syncs == 0, "a dropped call is not synced")
	assert(r.handlers.dropped == before + 1, "and it is counted")
end

return {
	{
		name = "every bad list argument is dropped and counted, with no market call",
		run = function()
			local nan = 0 / 0
			local bad: { { any } } = {
				{ "list", 5, 1, "fixed", 10, 6 },
				{ "list", "", 1, "fixed", 10, 6 },
				{ "list", string.rep("a", 33), 1, "fixed", 10, 6 },
				{ "list", "saddle", 0, "fixed", 10, 6 },
				{ "list", "saddle", 100, "fixed", 10, 6 },
				{ "list", "saddle", 1.5, "fixed", 10, 6 },
				{ "list", "saddle", nan, "fixed", 10, 6 },
				{ "list", "saddle", "1", "fixed", 10, 6 },
				{ "list", "saddle", 1, "dutch", 10, 6 },
				{ "list", "saddle", 1, 7, 10, 6 },
				{ "list", "saddle", 1, "fixed", 0, 6 },
				{ "list", "saddle", 1, "fixed", 100001, 6 },
				{ "list", "saddle", 1, "fixed", 10.5, 6 },
				{ "list", "saddle", 1, "fixed", math.huge, 6 },
				{ "list", "saddle", 1, "fixed", nan, 6 },
				{ "list", "saddle", 1, "fixed", 10, 2 },
				{ "list", "saddle", 1, "fixed", 10, 0 },
				{ "list", "saddle", 1, "fixed", 10, "6" },
				{ "list", "saddle", 1, "fixed", 10, nan },
				{ "list", "saddle", 1, "fixed", 10 },
				{ "list", "saddle", 1, "fixed" },
			}
			local r = rig()
			for _, args in bad do
				dropped(r, table.unpack(args, 1, 6))
			end
			assert(r.handlers.dropped == #bad, `{r.handlers.dropped} dropped`)
		end,
	},
	{
		name = "bad buy, bid, cancel and unknown-action arguments are dropped",
		run = function()
			local nan = 0 / 0
			local r = rig()
			dropped(r, "buy", 5, 10)
			dropped(r, "buy", "", 10)
			dropped(r, "buy", string.rep("a", 65), 10)
			dropped(r, "buy", "L1", 0)
			dropped(r, "buy", "L1", -3)
			dropped(r, "buy", "L1", 2.5)
			dropped(r, "buy", "L1", nan)
			dropped(r, "buy", "L1", math.huge)
			dropped(r, "buy", "L1", "10")
			dropped(r, "buy", "L1")
			dropped(r, "bid", "L1", 0)
			dropped(r, "bid", "L1", nan)
			dropped(r, "bid", "L1", 2 ^ 31 + 2)
			dropped(r, "bid", {}, 5)
			dropped(r, "cancel", 5)
			dropped(r, "cancel", "")
			dropped(r, "cancel", nil)
			dropped(r, "launch", "L1")
			dropped(r, 5, "L1")
			dropped(r, nil)
			dropped(r, { "list" })
		end,
	},
	{
		name = "good input reaches the market once, and the answer goes out with one sync",
		run = function()
			local r = rig()
			r.handlers:handle(1, "list", "saddle", 2, "auction", 50, 24)
			assert(r.calls[1] == "list 1 saddle 2 auction 50 24" and #r.calls == 1, tostring(r.calls[1]))
			assert(#r.syncs == 1 and r.syncs[1].userId == 1)
			local res = r.syncs[1].result
			assert(res.action == "list" and res.ok == true and res.id == "L1", res.action)
			r.handlers:handle(1, "buy", "L1", 60)
			assert(r.calls[2] == "buy 1 L1 60" and r.syncs[2].result.ok == true)
			r.handlers:handle(1, "bid", "L1", 70)
			assert(r.calls[3] == "bid 1 L1 70" and r.syncs[3].result.ok == true)
			r.handlers:handle(1, "cancel", "L1", "ignored")
			assert(r.calls[4] == "cancel 1 L1" and #r.syncs == 4)
			assert(r.handlers.dropped == 0)
			assert(#r.logs == 0)
		end,
	},
	{
		name = "the edges of the ranges are accepted",
		run = function()
			local r = rig()
			r.handlers:handle(1, "list", string.rep("a", 32), 99, "fixed", 100000, 1)
			r.handlers:handle(1, "list", "x", 1, "auction", 1, 24)
			r.handlers:handle(1, "buy", string.rep("b", 64), 1)
			r.handlers:handle(1, "bid", "L", 2 ^ 31)
			assert(#r.calls == 4 and r.handlers.dropped == 0, `{#r.calls} calls`)
		end,
	},
	{
		name = "a refusal is passed on with its reason, counts nothing and logs nothing",
		run = function()
			local r = rig()
			r.state.answer = "cant_afford"
			r.handlers:handle(1, "list", "saddle", 1, "fixed", 10, 6)
			r.handlers:handle(1, "buy", "L1", 10)
			assert(#r.calls == 2 and #r.syncs == 2)
			local list, buy = r.syncs[1].result, r.syncs[2].result
			assert(list.ok == false and list.reason == "cant_afford" and list.id == nil)
			assert(buy.ok == false and buy.reason == "cant_afford")
			assert(r.handlers.dropped == 0 and #r.logs == 0)
			r.state.answer = "pending"
			r.handlers:handle(1, "list", "saddle", 1, "fixed", 10, 6)
			assert(r.syncs[3].result.reason == "pending" and r.syncs[3].result.ok == false)
		end,
	},
	{
		name = "a market call that throws logs one line, is counted, and the player is still synced",
		run = function()
			local r = rig()
			r.state.throws = true
			r.handlers:handle(1, "buy", "L1", 10)
			assert(#r.logs == 1, `{#r.logs} log lines`)
			assert(string.find(r.logs[1], "market call failed for 1 (buy)", 1, true), r.logs[1])
			assert(r.handlers.dropped == 1)
			assert(#r.syncs == 1 and r.syncs[1].result == nil, "synced, with no result")
			assert(r.handlers:busy(1) == false, "and the guard is released")
			r.state.throws = false
			r.handlers:handle(1, "buy", "L1", 10)
			assert(#r.calls == 1, "the next call goes through")
		end,
	},
	{
		name = "a second call from a player whose first is still running is dropped and counted",
		run = function()
			local r = rig()
			r.handlers.deps.market.buy = function(_self: any): (any, any)
				r.handlers:handle(1, "cancel", "L2") -- the same player, mid-call
				return true, nil
			end
			r.handlers:handle(1, "buy", "L1", 10)
			assert(#r.calls == 0, "the inner call never reached the market")
			assert(r.handlers.dropped == 1, `{r.handlers.dropped} dropped`)
			assert(#r.syncs == 2, "the first call syncs, and the dropped one is told busy")
			assert(r.syncs[1].result.action == "cancel" and r.syncs[1].result.reason == "busy")
			assert(r.syncs[2].result.ok == true and r.syncs[2].result.action == "buy")
			assert(r.handlers:busy(1) == false, "released after")
		end,
	},
	{
		name = "a market that is busy with a settle drops the call, and busy reflects its lock",
		run = function()
			local r = rig()
			r.state.busy = true
			r.handlers:handle(1, "cancel", "L1")
			assert(r.handlers.dropped == 1 and #r.syncs == 1, "the market said busy")
			assert(
				r.syncs[1].result.ok == false and r.syncs[1].result.reason == "busy",
				"and the player is told"
			)
			r.handlers.deps.market.busy = function(): boolean
				return true
			end
			assert(r.handlers:busy(1) == true)
			r.state.busy = false
			r.handlers:handle(1, "cancel", "L1")
			assert(#r.calls == 1, "only the first reached the market")
			assert(r.handlers.dropped == 2, "a locked market drops the call before it is made")
			assert(#r.syncs == 2 and r.syncs[2].result.reason == "busy", "and says busy")
		end,
	},
	{
		name = "a player with no saveable session has the call dropped and no sync",
		run = function()
			local r = rig()
			r.handlers:handle(99, "list", "saddle", 1, "fixed", 10, 6)
			r.handlers:handle(99, "cancel", "L1")
			assert(#r.calls == 0 and #r.syncs == 0 and r.handlers.dropped == 2)
		end,
	},
	{
		name = "calls over the burst limit are dropped, and refill over time",
		run = function()
			local r = rig(3)
			for _ = 1, 5 do
				r.handlers:handle(1, "cancel", "L1")
			end
			assert(#r.calls == 3 and r.handlers.dropped == 2)
			r.handlers:handle(2, "cancel", "L1")
			assert(#r.calls == 4, "another player has their own allowance")
			r.clock:advance(2)
			r.handlers:handle(1, "cancel", "L1")
			assert(#r.calls == 5, "refilled")
		end,
	},
	{
		name = "a list-then-cancel loop is held to the store allowance and the rest are told to slow down",
		run = function()
			local r = rig()
			local burst, perMinute = Config.Limits.StoreBurstPerPlayer, Config.Limits.StoreOpsPerMinute
			local cost = Config.Limits.StoreCost
			local made, slow = 0, 0
			for _ = 1, 60 do -- two calls a second for a minute
				r.handlers:handle(1, "list", "saddle", 1, "fixed", 10, 6)
				r.clock:advance(0.5)
				r.handlers:handle(1, "cancel", "L1")
				r.clock:advance(0.5)
			end
			for _, s in r.syncs do
				if s.result ~= nil and s.result.reason == "slow_down" then
					slow += 1
					assert(s.result.ok == false)
				end
			end
			made = #r.calls
			assert(made <= (burst + perMinute) / cost.list, `{made} market calls`)
			assert(made >= 4, `{made} market calls`)
			assert(slow == 60 * 2 - made, `{slow} told to slow down`)
			assert(r.handlers.dropped == slow, "and each is counted")
		end,
	},
	{
		name = "buy and bid with made-up ids are charged like any store call",
		run = function()
			local r = rig()
			r.state.answer = "not_found"
			for i = 1, 20 do
				r.handlers:handle(1, if i % 2 == 0 then "buy" else "bid", "made-up-" .. i, 10)
			end
			local limit = Config.Limits.StoreBurstPerPlayer // Config.Limits.StoreCost.buy
			assert(#r.calls == limit, `{#r.calls} reached the market`)
			assert(r.syncs[#r.syncs].result.reason == "slow_down")
			assert(r.handlers.dropped == 20 - limit)
		end,
	},
	{
		name = "browse is not charged to the store allowance",
		run = function()
			local r = rig()
			for _ = 1, 50 do
				r.handlers:handle(1, "cancel", "L1")
				r.clock:advance(1)
				assert(r.handlers:browse(1, "price") ~= nil)
			end
			local spent = r.handlers.deps.storeLimiter.buckets[1]
			assert(spent ~= nil, "cancels were charged")
			local fresh = rig()
			for _ = 1, 100 do
				assert(fresh.handlers:browse(1, "price") ~= nil)
				fresh.clock:advance(1)
			end
			assert(fresh.handlers.deps.storeLimiter.buckets[1] == nil, "browse spent nothing")
		end,
	},
	{
		name = "browse returns one page of BrowsePageSize and shares the limiter",
		run = function()
			local r = rig(3)
			local page = r.handlers:browse(1, "price", nil)
			assert(page ~= nil and r.pages[1] == "price - 20", tostring(r.pages[1]))
			r.handlers:browse(1, "ending", { key = "k", sortKey = 120, extra = "ignored" })
			assert(r.pages[2] == "ending k/120 20", tostring(r.pages[2]))
			r.handlers:handle(1, "cancel", "L1")
			assert(r.handlers:browse(1, "price", nil) == nil, "the burst of 3 is spent across both")
			assert(r.handlers.dropped == 1 and #r.pages == 2)
		end,
	},
	{
		name = "bad browse arguments are dropped and counted, and never reach the index",
		run = function()
			local nan = 0 / 0
			local r = rig()
			local bad: { { any } } = {
				{ "cheap" },
				{ 5 },
				{ "price", "k" },
				{ "price", { key = 5, sortKey = 1 } },
				{ "price", { key = "", sortKey = 1 } },
				{ "price", { key = string.rep("a", 65), sortKey = 1 } },
				{ "price", { key = "k" } },
				{ "price", { key = "k", sortKey = nan } },
				{ "price", { key = "k", sortKey = math.huge } },
				{ "price", { key = "k", sortKey = 1.5 } },
				{ "price", { key = "k", sortKey = -1 } },
				{ "price", { key = "k", sortKey = "1" } },
			}
			for _, args in bad do
				assert(r.handlers:browse(1, args[1], args[2]) == nil)
			end
			assert(r.handlers:browse(1, nil, nil) == nil)
			assert(#r.pages == 0, "nothing reached the index")
			assert(r.handlers.dropped == #bad + 1, `{r.handlers.dropped} dropped`)
		end,
	},
}
