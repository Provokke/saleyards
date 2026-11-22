--!strict
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local FakeDataStore = require("../fakes/FakeDataStore")
local FakeSortedMap = require("../fakes/FakeSortedMap")
local Faults = require("../fakes/Faults")
local Index = require("../../src/server/Index")
local Listing = require("../../src/server/Listing")
local Market = require("../../src/server/Market")
local Settle = require("../../src/server/Settle")
local TestProfiles = require("../fakes/TestProfiles")

local function rig(): any
	local r: any = { records = {}, logs = {}, failSave = false, failGet = false }
	r.store = FakeDataStore.new(r.records)
	r.faults = Faults.new()
	local handle = r.store:handle(r.faults)
	r.clock = FakeClock.new(1000)
	local now = function()
		return r.clock:now()
	end
	local profiles = TestProfiles.new(handle, Config.StartingCoins, Config.StartingItems)
	r.profiles = profiles
	r.byPrice = FakeSortedMap.new(r.clock)
	r.byEnding = FakeSortedMap.new(r.clock)
	r.index = Index.new(r.byPrice:handle(r.faults), r.byEnding:handle(r.faults), now, function() end)
	local n = 0
	r.market = Market.new({
		listings = handle,
		index = r.index,
		profiles = {
			get = function(userId: number): any
				if r.failGet then
					error("boom")
				end
				return profiles:get(userId)
			end,
			save = function(userId: number): boolean
				if r.failSave then
					return false
				end
				return profiles:save(userId)
			end,
		},
		now = now,
		guid = function(): string
			n += 1
			return "G" .. n
		end,
		log = function(line: string)
			table.insert(r.logs, line)
		end,
		config = Config,
		Listing = Listing,
		settler = Settle.new(Listing),
	})
	return r
end

local function p(r: any, userId: number): any
	return r.profiles:get(userId)
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- User 1 lists 2 hay bales at a fixed price, or one fleece as an auction, for one hour.
local function listed(r: any, kind: string, price: number): string
	local fixed = kind == "fixed"
	local id, err =
		r.market:list(1, if fixed then "hay_bale" else "fleece", if fixed then 2 else 1, kind, price, 1)
	assert(id, err)
	return id
end

return {
	{
		name = "list takes items and fee, saves the claim before the listing write",
		run = function()
			local r = rig()
			r.store.events = {}
			local id = listed(r, "fixed", 40)
			assert(id == "G1")
			local profile = p(r, 1)
			assert(profile.items.hay_bale == 4 and profile.coins == 495)
			assert(count(profile.claims) == 1 and profile.claims[id].kind == "listing")
			assert(r.records["listing/G1"].state == "open")
			assert(r.records["profile/1"].claims[id] ~= nil and r.records["profile/1"].coins == 495)
			assert(r.store.events[1] == "call profile/1" and r.store.events[2] == "call listing/G1")
			assert(#r.index:page("price", nil, 5).entries == 1)
		end,
	},
	{
		name = "list refusals change nothing and write nothing",
		run = function()
			local r = rig()
			local before = Deep.copy(p(r, 1))
			local cases: { { any } } = {
				{ "hay_bale", 99, "fixed", 40, 1, "not_enough_items" },
				{ "hay_bale", 2, "fixed", 40, 2, "bad_hours" },
				{ "hay_bale", 2, "fixed", 0, 1, "bad_price" },
				{ "nope", 2, "fixed", 40, 1, "bad_item" },
			}
			for _, c in cases do
				local id, err = r.market:list(1, c[1], c[2], c[3], c[4], c[5])
				assert(id == nil and err == c[6], err)
			end
			p(r, 1).coins = 0
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "cant_afford")
			p(r, 1).coins = before.coins
			for i = 1, 10 do
				p(r, 1).claims["x" .. i] = { id = "x" .. i }
			end
			id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "too_many_claims")
			for i = 1, 10 do
				p(r, 1).claims["x" .. i] = nil
			end
			assert(Deep.equal(p(r, 1), before))
			assert(r.faults.writes == 0 and r.store.calls == 0)
		end,
	},
	{
		name = "list with a failed save rolls back and writes no listing",
		run = function()
			local r = rig()
			local before = Deep.copy(p(r, 1))
			r.failSave = true
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "save_failed")
			assert(Deep.equal(p(r, 1), before))
			assert(r.faults.writes == 0 and r.records["listing/G1"] == nil)
		end,
	},
	{
		name = "list returns the id when the create landed but the response was lost",
		run = function()
			local r = rig()
			r.faults:arm(2, "lost") -- write 1 is the profile save, write 2 is the create
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == "G1", err)
			assert(r.records["listing/G1"].state == "open")
			assert(p(r, 1).claims["G1"] ~= nil)
			assert(p(r, 1).coins == 495 and p(r, 1).items.hay_bale == 4)
		end,
	},
	{
		name = "list whose create never landed is voided and returns the item and the fee",
		run = function()
			local r = rig()
			local real = r.store.UpdateAsync
			local failed = false
			r.store.UpdateAsync = function(self: any, key: string, transform: any): any
				if not failed and key == "listing/G1" then
					failed = true
					error("timeout")
				end
				return real(self, key, transform)
			end
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "not_listed", err)
			assert(p(r, 1).items.hay_bale == 6 and p(r, 1).coins == 500 and count(p(r, 1).claims) == 0)
			assert(r.records["listing/G1"].state == "void")
		end,
	},
	{
		name = "buy settles both sides, exactly once",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			local ok, err = r.market:buy(2, id, 40)
			assert(ok == true, err)
			assert(p(r, 2).coins == 460 and p(r, 2).items.hay_bale == 8 and count(p(r, 2).claims) == 0)
			assert(r.records["listing/" .. id].state == "sold")
			assert(r.market:settle(1) == 1)
			assert(p(r, 1).coins == 531 and count(p(r, 1).claims) == 0)
			assert(r.records["listing/" .. id].settled.seller == true)
			local again = Deep.copy(p(r, 1))
			assert(r.market:settle(1) == 0)
			assert(Deep.equal(p(r, 1), again))
		end,
	},
	{
		name = "buy refusals move no Coins",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			local before = Deep.copy(p(r, 2))
			local writes = r.faults.writes
			local ok, err = r.market:buy(2, id, 41)
			assert(ok == false and err == "price_changed")
			ok, err = r.market:buy(1, id, 40)
			assert(ok == false and err == "own_listing")
			ok, err = r.market:buy(2, "missing", 40)
			assert(ok == false and err == "missing")
			p(r, 2).coins = 10
			ok, err = r.market:buy(2, id, 40)
			assert(ok == nil and err == "cant_afford")
			p(r, 2).coins = 500
			assert(Deep.equal(p(r, 2), before) and r.faults.writes == writes)
		end,
	},
	{
		name = "a second buyer after the sale is refunded in full by its own settle",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			assert(r.market:buy(2, id, 40) == true)
			-- User 3 read the listing as open, then user 2's buy landed: stake it by hand.
			local late = p(r, 3)
			late.coins -= 40
			late.claims["late"] = {
				kind = "buy",
				listingId = id,
				itemId = "hay_bale",
				qty = 2,
				amount = 40,
				id = "late",
				at = 1000,
			}
			assert(r.market:settle(3) == 1)
			assert(late.coins == 500 and late.items.hay_bale == 6 and count(late.claims) == 0)
			assert(r.records["listing/" .. id].voided.late == true)
			assert(r.records["listing/" .. id].buyer.userId == 2)
		end,
	},
	{
		name = "bid war: the loser is refunded, the winner gets the item, the seller is paid",
		run = function()
			local r = rig()
			local id = listed(r, "auction", 20)
			assert(r.market:bid(2, id, 20) == true)
			assert(r.market:bid(3, id, 25) == true)
			assert(r.market:bid(2, id, 30) == true)
			local ok, err = r.market:bid(3, id, 31)
			assert(ok == false and err == "too_low")
			r.clock:advance(3601)
			assert(r.market:settle(3) == 1 and p(r, 3).coins == 500)
			assert(r.market:settle(2) == 1)
			assert(p(r, 2).coins == 470 and p(r, 2).items.fleece == 5 and count(p(r, 2).claims) == 0)
			assert(r.market:settle(1) == 1)
			assert(p(r, 1).coins == 500 - 5 + 27 and count(p(r, 1).claims) == 0)
		end,
	},
	{
		name = "bid refuses the current high bidder without staking",
		run = function()
			local r = rig()
			local id = listed(r, "auction", 20)
			assert(r.market:bid(2, id, 20) == true)
			local ok, err = r.market:bid(2, id, 40)
			assert(ok == false and err == "already_high")
			assert(p(r, 2).coins == 480 and count(p(r, 2).claims) == 1)
		end,
	},
	{
		name = "cancel returns the items without the fee, and only for the seller",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			local denied, why = r.market:cancel(2, id)
			assert(denied == false and why == "not_yours")
			assert(r.market:cancel(1, id) == true)
			assert(p(r, 1).items.hay_bale == 6 and p(r, 1).coins == 495 and count(p(r, 1).claims) == 0)
		end,
	},
	{
		name = "an unsold listing past its end returns the items without the fee",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			assert(r.market:settle(1) == 0 and count(p(r, 1).claims) == 1)
			r.clock:advance(3601)
			assert(r.market:settle(1) == 1)
			assert(p(r, 1).items.hay_bale == 6 and p(r, 1).coins == 495 and count(p(r, 1).claims) == 0)
			assert(r.records["listing/" .. id].settled.seller == true)
		end,
	},
	{
		name = "the lock refuses a second call for the same user only, and frees after a raise",
		run = function()
			local r = rig()
			local co = coroutine.create(function()
				r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			r.store:hookNext(function()
				coroutine.yield()
			end)
			coroutine.resume(co)
			assert(coroutine.status(co) == "suspended" and r.market:busy(1))
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "busy")
			local n, why = r.market:settle(1)
			assert(n == nil and why == "busy")
			local other = r.market:list(2, "hay_bale", 2, "fixed", 40, 1)
			assert(other ~= nil and not r.market:busy(2))
			coroutine.resume(co)
			assert(coroutine.status(co) == "dead" and not r.market:busy(1))
			r.failGet = true
			local ok = pcall(r.market.settle, r.market, 1)
			assert(not ok and not r.market:busy(1))
			r.failGet = false
			assert(r.market:settle(1) ~= nil)
		end,
	},
	{
		name = "a raise while settling leaves the claim in place",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			r.clock:advance(3601)
			r.faults.dead = true
			assert(r.market:settle(1) == 0)
			assert(p(r, 1).claims[id] ~= nil and p(r, 1).items.hay_bale == 4)
		end,
	},
}
