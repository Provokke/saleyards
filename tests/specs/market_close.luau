--!strict
-- Two or more servers on one store. Covers the cases a single-server rig cannot: a seller's read
-- served from a cache, a server whose clock is behind, and ids that collide across servers. Every
-- scenario runs twice: once with the real settler, and once as its own negative control with a
-- settler that skips the fix, which has to fail conservation.
local Config = require("../../src/shared/Config")
local Conservation = require("../fakes/Conservation")
local FakeClock = require("../fakes/FakeClock")
local FakeDataStore = require("../fakes/FakeDataStore")
local FakeSortedMap = require("../fakes/FakeSortedMap")
local Faults = require("../fakes/Faults")
local Index = require("../../src/server/Index")
local Listing = require("../../src/server/Listing")
local Market = require("../../src/server/Market")
local Settle = require("../../src/server/Settle")
local TestProfiles = require("../fakes/TestProfiles")

local USERS = { 1, 2, 3 }
local HOUR = 3600
local realSettler = Settle.new(Listing)

-- Decides from the plain read: never closes a listing, as Market did before the close write.
local noClose: any = {
	decide = realSettler.decide,
	needsClose = function(): boolean
		return false
	end,
}

-- Decides without any ownership check: a claim follows whatever listing sits under its id.
local noOwnership: any = {
	decide = function(claim: any, listing: any, now: number, saleTax: number, userId: number): any
		local who = userId
		if listing ~= nil and listing.state ~= "void" and claim.kind == "listing" then
			who = listing.seller
		end
		return realSettler.decide(claim, listing, now, saleTax, who)
	end,
	needsClose = realSettler.needsClose,
}

type Opts = { skew: number?, cache: boolean?, settler: any? }

local function world(): any
	local w: any = { records = {}, servers = {}, n = 0 }
	w.store = FakeDataStore.new(w.records)
	w.clockA = FakeClock.new(1000)
	w.byPrice = FakeSortedMap.new(w.clockA)
	w.byEnding = FakeSortedMap.new(w.clockA)
	return w
end

-- One server with its own clock (skew is added to the world's start), its own profiles and its own
-- guid prefix, so ids only collide when a scenario asks for it.
local function server(w: any, prefix: string, opts: Opts?): any
	local o: Opts = opts or {}
	local s: any = { faults = Faults.new(), logs = {}, clock = FakeClock.new(1000 + (o.skew or 0)) }
	local clock = s.clock
	local handle = w.store:handle(s.faults, if o.cache then { cacheSeconds = 4, clock = clock } else nil)
	local now = function(): number
		return clock:now()
	end
	local log = function(line: string)
		table.insert(s.logs, line)
	end
	s.profiles = TestProfiles.new(handle, Config.StartingCoins, Config.StartingItems)
	s.index = Index.new(w.byPrice:handle(s.faults), w.byEnding:handle(s.faults), now, log)
	local n = 0
	s.market = Market.new({
		listings = handle,
		index = s.index,
		profiles = {
			get = function(userId: number): any
				return s.profiles:get(userId)
			end,
			save = function(userId: number): boolean
				return s.profiles:save(userId)
			end,
		},
		now = now,
		guid = function(): string
			n += 1
			return prefix .. n
		end,
		log = log,
		config = Config,
		Listing = Listing,
		settler = o.settler or realSettler,
	})
	table.insert(w.servers, s)
	return s
end

local function advance(w: any, seconds: number)
	for _, s in w.servers do
		s.clock:advance(seconds)
	end
end

-- Each user settles on the server that holds them, until nothing is left, then the world is checked.
local function check(w: any, homes: { [number]: any }): (boolean, string?)
	advance(w, 10)
	for _ = 1, 3 do
		for _, userId in USERS do
			local home = homes[userId]
			if home ~= nil then
				home.market:settle(userId)
			end
		end
	end
	local coins: { [number]: number } = {}
	local items: { [number]: { [string]: number } } = {}
	for _, userId in USERS do
		coins[userId] = Config.StartingCoins
		items[userId] = Config.StartingItems
	end
	return Conservation.check(w.records, coins, items, Config.SaleTax, w.servers[1].clock:now())
end

local function profile(s: any, userId: number): any
	return s.profiles:get(userId)
end

-- The seller's cached read says open; a buyer on another server buys just before the end.
local function staleFixed(settler: any?): (boolean, string?, any, any)
	local w = world()
	local a = server(w, "A", { cache = true, settler = settler })
	local b = server(w, "B")
	local id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
	assert(id ~= nil)
	advance(w, HOUR - 2)
	a.market:settle(1) -- reads the listing as open and caches it
	advance(w, 1)
	assert(b.market:buy(2, id, 40) == true)
	advance(w, 2)
	a.market:settle(1) -- one second past the end, the read is still inside the 4 s cache
	local ok, why = check(w, { a, b, b })
	return ok, why, profile(a, 1), profile(b, 2)
end

-- Two bids, the second lands from another server just before the end, the seller reads the first.
local function staleAuction(settler: any?): (boolean, string?, any, any, any)
	local w = world()
	local a = server(w, "A", { cache = true, settler = settler })
	local b = server(w, "B")
	local id = a.market:list(1, "fleece", 1, "auction", 20, 1)
	assert(id ~= nil)
	assert(b.market:bid(2, id, 20) == true)
	advance(w, HOUR - 2)
	a.market:settle(1)
	advance(w, 1)
	assert(b.market:bid(3, id, 50) == true)
	advance(w, 2)
	a.market:settle(1)
	local ok, why = check(w, { a, b, b })
	return ok, why, profile(a, 1), profile(b, 2), profile(b, 3)
end

-- B's clock is 2 s behind: it still takes a bid after A's clock has passed the end.
local function skew(settler: any?): (boolean, string?, any, any, any, any)
	local w = world()
	local a = server(w, "A", { settler = settler })
	local b = server(w, "B", { skew = -2, settler = settler })
	local id = a.market:list(1, "fleece", 1, "auction", 20, 1)
	assert(id ~= nil)
	assert(b.market:bid(2, id, 20) == true)
	advance(w, HOUR) -- A is at the end, B is two seconds short of it
	assert(b.market:bid(3, id, 30) == true)
	a.market:settle(1) -- closes the listing on A (or, broken, pays on an open one)
	local later, why = b.market:bid(2, id, 40)
	local ok, msg = check(w, { a, b, b })
	return ok, msg, profile(a, 1), profile(b, 2), profile(b, 3), { later, why }
end

return {
	{
		name = "close: the seller's cached open read cannot refund items that a buyer bought",
		run = function()
			local ok, why, seller, buyer = staleFixed()
			assert(ok, why)
			assert(seller.coins == 500 - 5 + 36 and seller.items.hay_bale == 4)
			assert(buyer.coins == 460 and buyer.items.hay_bale == 8)
		end,
	},
	{
		name = "close negative control: deciding from the cached read duplicates the items",
		run = function()
			local ok, why, seller, buyer = staleFixed(noClose)
			assert(not ok, "the broken path should fail conservation")
			assert(
				string.find(why or "", "hay_bale", 1, true) ~= nil or string.find(why or "", "coins", 1, true)
			)
			-- It really took the stale path: the seller got the items back and the buyer kept theirs.
			assert(seller.items.hay_bale == 6 and buyer.items.hay_bale == 8)
		end,
	},
	{
		name = "close: the seller is paid the late high bid that a cached read missed",
		run = function()
			local ok, why, seller, loser, winner = staleAuction()
			assert(ok, why)
			assert(seller.coins == 500 - 5 + 45 and seller.items.fleece == 3)
			assert(loser.coins == 500 and loser.items.fleece == 4)
			assert(winner.coins == 450 and winner.items.fleece == 5)
		end,
	},
	{
		name = "close negative control: the cached high bid pays the seller too little",
		run = function()
			local ok, _, seller = staleAuction(noClose)
			assert(not ok, "the broken path should fail conservation")
			assert(seller.coins == 500 - 5 + 18, "it did not take the stale path")
		end,
	},
	{
		name = "close: a server behind by 2 s is refused once the end is written, one bidder wins",
		run = function()
			local ok, why, seller, low, high, again = skew()
			assert(ok, why)
			assert(again[1] == false and again[2] == "not_open")
			assert(seller.coins == 500 - 5 + 27)
			assert(low.items.fleece == 4 and low.coins == 500)
			assert(high.items.fleece == 5 and high.coins == 470)
		end,
	},
	{
		name = "close negative control: without the end written, the lagging server takes a bid after the payout",
		run = function()
			local ok, _, seller, _, _, again = skew(noClose)
			assert(not ok, "the broken path should fail conservation")
			assert(again[1] == true, "the late bid was not accepted, so it did not take the broken path")
			assert(seller.coins == 500 - 5 + 27)
		end,
	},
	{
		name = "ownership: a listing claim that lost the id to another seller is returned with its fee",
		run = function()
			local w = world()
			local a = server(w, "G") -- both servers count from G1: the guid collides
			local b = server(w, "G")
			local id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == "G1")
			local second, why = b.market:list(3, "fleece", 1, "fixed", 30, 1)
			assert(second == nil and why == "not_listed", why)
			local three = profile(b, 3)
			assert(three.items.fleece == 4 and three.coins == 500 and next(three.claims) == nil)
			assert(w.records["listing/G1"].seller == 1 and w.records["listing/G1"].itemId == "hay_bale")
			-- User 1's listing is untouched and still sells normally.
			assert(a.market:list(1, "hay_bale", 1, "fixed", 10, 1) ~= nil)
			assert(w.records["listing/G1"].state == "open")
			advance(w, HOUR + 1)
			local ok, msg = check(w, { a, b, b })
			assert(ok, msg)
		end,
	},
	{
		name = "ownership negative control: with no owner check the second seller is kept on the first one's listing",
		run = function()
			local w = world()
			local a = server(w, "G", { settler = noOwnership })
			local b = server(w, "G", { settler = noOwnership })
			assert(a.market:list(1, "hay_bale", 2, "fixed", 40, 1) == "G1")
			local second = b.market:list(3, "fleece", 1, "fixed", 30, 1)
			assert(second == "G1", "the broken path should report the other seller's listing as ours")
			advance(w, HOUR + 1)
			local ok = check(w, { a, b, b })
			assert(not ok, "the broken path should fail conservation")
		end,
	},
}
