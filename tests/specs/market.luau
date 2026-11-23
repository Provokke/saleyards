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

local function rig(settler: any?): any
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
	r.indexFaults = Faults.new() -- the index has its own faults, so a dead store does not take it down
	r.index = Index.new(
		r.byPrice:handle(r.indexFaults),
		r.byEnding:handle(r.indexFaults),
		now,
		function() end
	)
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
			save = function(userId: number, _: any, undo: (() -> ())?): boolean
				if r.onSave then
					r.onSave()
				end
				if r.failSave then
					if undo ~= nil then
						undo()
					end
					return false
				end
				return profiles:save(userId, undo)
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
		settler = settler or Settle.new(Listing),
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
			-- Each call settled only its own claim, so bidder 2 still holds the outbid first bid
			-- and the winning one.
			assert(r.market:settle(2) == 2)
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
	{
		name = "list returns pending, not an id, while its claim is held with no decision",
		run = function()
			local r = rig()
			r.faults:arm(2, "stop") -- the create never lands and the server is dead for the fallback settle
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "pending", err)
			assert(p(r, 1).claims["G1"] ~= nil)
			assert(r.records["listing/G1"] == nil)
		end,
	},
	{
		name = "cancel reports success when the write landed but its answer was lost",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			r.faults:arm(1, "lost")
			local ok, err = r.market:cancel(1, id)
			assert(ok == true, err)
			assert(r.records["listing/" .. id].state == "cancelled")
			assert(p(r, 1).items.hay_bale == 6 and count(p(r, 1).claims) == 0)
		end,
	},
	{
		name = "cancel and a sale take the listing out of the browse index",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			assert(#r.index:page("price", nil, 5).entries == 1)
			assert(r.market:cancel(1, id) == true)
			assert(#r.index:page("price", nil, 5).entries == 0)
			local sold = listed(r, "fixed", 40)
			assert(#r.index:page("price", nil, 5).entries == 1)
			assert(r.market:buy(2, sold, 40) == true)
			assert(
				#r.index:page("price", nil, 5).entries == 0,
				"the sale takes it out of the cache without waiting for the seller"
			)
			assert(r.market:settle(1) == 1)
			assert(#r.index:page("price", nil, 5).entries == 0)
		end,
	},
	{
		name = "a landed cancel leaves the browse index even when settling cannot read the listing",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			r.store:hookNext(function()
				r.faults.dead = true -- the cancel lands, then the settle's read raises
			end)
			assert(r.market:cancel(1, id) == true)
			assert(count(p(r, 1).claims) == 1, "the settle should not have run")
			assert(#r.index:page("price", nil, 5).entries == 0)
		end,
	},
	{
		name = "buy that landed but cannot be read back is pending, and the item arrives at the next settle",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			r.store:hookNext(function() end) -- the stake's profile save
			r.store:hookNext(function()
				r.faults.dead = true -- the buy lands, then every read raises
			end)
			local ok, err = r.market:buy(2, id, 40)
			assert(ok == nil and err == "pending", err)
			assert(r.records["listing/" .. id].state == "sold" and count(p(r, 2).claims) == 1)
			r.faults.dead = false
			assert(r.market:settle(2) == 1)
			assert(p(r, 2).items.hay_bale == 8 and p(r, 2).coins == 460)
		end,
	},
	{
		name = "bid that landed but cannot be read back is pending, not a refusal",
		run = function()
			local r = rig()
			local id = listed(r, "auction", 20)
			r.store:hookNext(function() end)
			r.store:hookNext(function()
				r.faults.dead = true
			end)
			local ok, err = r.market:bid(2, id, 20)
			assert(ok == nil and err == "pending", err)
			assert(r.records["listing/" .. id].high.userId == 2)
			r.faults.dead = false
			assert(r.market:settle(2) == 0 and count(p(r, 2).claims) == 1)
		end,
	},
	{
		name = "a failed list save puts the items back relative to what changed during the save",
		run = function()
			local r = rig()
			r.failSave = true
			r.onSave = function()
				p(r, 1).items.hay_bale += 10 -- a reward granted while the save yields
			end
			local id, err = r.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			assert(id == nil and err == "save_failed")
			assert(p(r, 1).items.hay_bale == 16 and p(r, 1).coins == 500 and count(p(r, 1).claims) == 0)
		end,
	},
	{
		name = "a failed stake write is logged",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			r.faults:arm(2, "stop") -- write 1 is the stake's save, write 2 is the buy
			assert(r.market:buy(2, id, 40) == nil)
			local found = false
			for _, line in r.logs do
				if string.find(line, "stake write failed", 1, true) then
					found = true
				end
			end
			assert(found, "no log line for the failed stake write")
		end,
	},
	{
		name = "an error inside the decision raises out of settle and frees the lock",
		run = function()
			local real = Settle.new(Listing)
			local boom: any = {
				decide = function(): any
					error("decide bug")
				end,
				needsClose = real.needsClose,
			}
			local r = rig(boom)
			listed(r, "fixed", 40)
			local ok, err = pcall(r.market.settle, r.market, 1)
			assert(not ok and string.find(tostring(err), "decide bug", 1, true) ~= nil)
			assert(not r.market:busy(1) and count(p(r, 1).claims) == 1)
		end,
	},
	{
		name = "settle returns whether the profile saved",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			assert(r.market:buy(2, id, 40) == true)
			r.failSave = true
			local applied, saved = r.market:settle(1)
			assert(applied == 1 and saved == false)
			r.failSave = false
			local second = listed(r, "fixed", 40)
			assert(r.market:buy(2, second, 40) == true)
			applied, saved = r.market:settle(1)
			assert(applied == 1 and saved == true)
			applied, saved = r.market:settle(1)
			assert(applied == 0 and saved == true)
		end,
	},
	{
		name = "notices are in plain words with item names, never item ids",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			assert(r.market:buy(2, id, 40) == true)
			assert(r.market:settle(1) == 1)
			local sold = p(r, 1).notices[#p(r, 1).notices].text
			local bought = p(r, 2).notices[#p(r, 2).notices].text
			local listing = r.records["listing/" .. id]
			local name = Config.Items[listing.itemId].name
			assert(string.find(sold, "sold for 36 Coins", 1, true) and string.find(sold, name, 1, true), sold)
			assert(string.sub(bought, 1, 11) == "You bought " and string.find(bought, name, 1, true), bought)
			for _, text in { sold, bought } do
				assert(not string.find(text, listing.itemId, 1, true), `item id shown: {text}`)
			end
		end,
	},
	{
		name = "a landed bid puts the current high bid in the browse cache",
		run = function()
			local r = rig()
			local id = listed(r, "auction", 20)
			local function entry(): any
				for _, item in r.byPrice:GetRangeAsync("Ascending", 10) do
					if item.key == id then
						return item
					end
				end
				return nil
			end
			assert(entry() ~= nil and entry().value.high == nil, "no bid yet")
			assert(r.market:bid(2, id, 20) == true)
			assert(entry().value.high == 20 and entry().sortKey == 20)
			assert(r.market:bid(3, id, 25) == true)
			assert(entry().value.high == 25 and entry().sortKey == 25, "the price sort follows the high bid")
		end,
	},
	{
		name = "cancel is refused before any store call unless the player holds the listing's claim",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			p(r, 2) -- load both profiles first
			local reads = 0
			r.faults.onRead = function()
				reads += 1
			end
			local writes = r.faults.writes
			local ok, err = r.market:cancel(2, id) -- a player with no claim on it
			assert(ok == false and err == "not_yours", tostring(err))
			ok, err = r.market:cancel(1, "made-up")
			assert(ok == false and err == "not_yours", tostring(err))
			assert(reads == 0 and r.faults.writes == writes, "no store call was made")
			assert(r.records["listing/" .. id].state == "open", "the listing is untouched")
			-- control: the seller holds the claim, and the same call goes through
			assert(r.market:cancel(1, id) == true)
			assert(r.faults.writes > writes, "the cancel wrote")
		end,
	},
	{
		name = "buy settles only the claim it made, so held claims cost no reads until a full settle",
		run = function()
			local r = rig()
			for _ = 1, 3 do
				local id = listed(r, "auction", 20)
				assert(r.market:bid(2, id, 20) == true)
			end
			local fixed = listed(r, "fixed", 40)
			assert(count(p(r, 2).claims) == 3, "three bid claims held")
			local reads = 0
			r.faults.onRead = function()
				reads += 1
			end
			assert(r.market:buy(2, fixed, 40) == true)
			assert(reads == 2, `{reads} reads: the pre-read and its own claim, none for the three held`)
			assert(count(p(r, 2).claims) == 3, "the held claims are left to the poll")
			-- control: a full settle reads each held claim
			reads = 0
			r.market:settle(2)
			assert(reads == 3, `{reads} reads for three claims`)
		end,
	},
	{
		name = "a cancel settles only its own listing claim",
		run = function()
			local r = rig()
			local a = listed(r, "fixed", 40)
			local b = listed(r, "auction", 20)
			local reads = 0
			r.faults.onRead = function()
				reads += 1
			end
			assert(r.market:cancel(1, a) == true)
			assert(reads == 1, `{reads} reads`)
			assert(p(r, 1).claims[b] ~= nil, "the other listing's claim is still held")
		end,
	},
	{
		name = "a claim whose id points at someone else's listing is returned and that listing is not written",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40) -- user 1's
			local before = Deep.copy(r.records["listing/" .. id])
			p(r, 3).claims[id] = {
				kind = "listing",
				listingId = id,
				itemId = "hay_bale",
				qty = 2,
				amount = 40,
				fee = 5,
				id = id,
				at = 1000,
			}
			assert(r.market:settle(3) == 1)
			assert(count(p(r, 3).claims) == 0 and p(r, 3).items.hay_bale == 8, "returned to its holder")
			assert(Deep.equal(r.records["listing/" .. id], before), "the other player's listing is unchanged")
		end,
	},
	{
		name = "a buy refused as not open takes the stale listing out of the browse cache",
		run = function()
			local r = rig()
			local id = listed(r, "fixed", 40)
			local open = Deep.copy(r.records["listing/" .. id])
			assert(r.market:buy(2, id, 40) == true)
			r.index:add(open) -- a stale entry, as another server's cache can still hold
			assert(#r.index:page("price", nil, 5).entries == 1)
			local done, reason = r.market:buy(3, id, 40)
			assert(done == false and reason == "not_open", tostring(reason))
			assert(#r.index:page("price", nil, 5).entries == 0, "found out, so dropped")
		end,
	},
}
