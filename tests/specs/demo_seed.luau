--!strict
-- The Studio demo data: what it writes, that it stays off outside Studio, and that the pre-sold
-- listing settles into a payout notice.
local Config = require("../../src/shared/Config")
local DemoSeed = require("../../src/server/DemoSeed")
local FakeGame = require("../fakes/FakeGame")
local Listing = require("../../src/server/Listing")
local World = require("../harness/World")

local SELLERS = { 101, 102, 103, 104, 105, 106 }
local ITEMS = { "hay_bale", "fleece", "horseshoe", "saddle", "milk_can", "wool_bale" }
local ENV = { Listing = Listing, items = ITEMS, fee = Config.ListingFee }

local function listingKeys(records: any): { string }
	local keys = {}
	for key in records do
		if string.sub(key, 1, 8) == "listing/" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	return keys
end

local function seeded(playerUserId: number?): (any, any, any)
	local world = World.new()
	local s = world:server("a")
	local handle = world.store:handle(s.faults)
	local result = DemoSeed.seed(handle, s.index, world.clock:now(), SELLERS, playerUserId, ENV)
	return world, s, result
end

return {
	{
		name = "six pretend sellers list a mix of fixed and auction, and one auction ends in 90 seconds",
		run = function()
			local world, s = seeded(nil)
			local keys = listingKeys(world.records)
			assert(#keys == 7, `{#keys} listings`)
			local fixed, auction, sellers = 0, 0, {}
			for _, key in keys do
				local l = world.records[key]
				assert(l.state == "open" and l.fee == Config.ListingFee)
				assert(Config.Items[l.itemId] ~= nil, "a real item")
				if l.kind == "fixed" then
					fixed += 1
				else
					auction += 1
				end
				sellers[l.seller] = true
			end
			assert(fixed >= 2 and auction >= 2, `{fixed} fixed, {auction} auction`)
			for _, id in SELLERS do
				assert(sellers[id], `seller {id} has a listing`)
			end
			local ending = world.records["listing/demo-ending"]
			assert(ending.seller == 104 and ending.kind == "auction")
			assert(ending.endsAt == world.clock:now() + 90, tostring(ending.endsAt))
			local page = s.index:page("ending", nil, 20)
			assert(#page.entries == 7 and page.entries[1].id == "demo-ending", "in the index, soonest first")
		end,
	},
	{
		name = "every demo listing is one Listing.create would make",
		run = function()
			local world = seeded(nil)
			for _, key in listingKeys(world.records) do
				local l = world.records[key]
				local again, reason = Listing.create(nil, {
					id = l.id,
					seller = l.seller,
					itemId = l.itemId,
					qty = l.qty,
					kind = l.kind,
					price = l.price,
					startBid = l.startBid,
					fee = l.fee,
					endsAt = l.endsAt,
				}, world.clock:now())
				assert(again ~= nil, tostring(reason))
				assert(require("../fakes/Deep").equal(again, l), `{key} differs from a fresh create`)
			end
		end,
	},
	{
		name = "seeding twice makes no duplicates and no second payout",
		run = function()
			local world, s, first = seeded(7)
			assert(first.claim ~= nil)
			local handle = world.store:handle(s.faults)
			local second = DemoSeed.seed(handle, s.index, world.clock:now(), SELLERS, 7, ENV)
			assert(#second.ids == 0 and second.claim == nil, "everything already exists")
			assert(#listingKeys(world.records) == 8)
		end,
	},
	{
		name = "the pre-sold listing for the player settles into a payout notice",
		run = function()
			local world, s, result = seeded(7)
			local sold = world.records["listing/demo-sold-7"]
			assert(sold.state == "sold" and sold.buyer.userId == 105 and sold.seller == 7)
			local claim = result.claim
			assert(claim ~= nil and claim.kind == "listing" and claim.listingId == "demo-sold-7")
			local profile = s.profiles:get(7)
			local before = profile.coins
			profile.claims[claim.id] = claim
			local applied, saved = s.market:settle(7)
			assert(applied == 1 and saved == true, `{applied}, {saved}`)
			assert(profile.coins == before + 120 - 12, `{profile.coins} coins`)
			assert(next(profile.claims) == nil)
			assert(#profile.notices == 1 and string.find(profile.notices[1].text, "108 Coins", 1, true))
			assert(world.records["listing/demo-sold-7"].settled.seller == true)
		end,
	},
	{
		name = "the entry script seeds in Studio with the attribute and in-memory stores, and not otherwise",
		run = function()
			local function run(options: any): any
				local world = FakeGame.new(options)
				world:start()
				assert(world.started == true, world.startError)
				world:join(7)
				world.sched:advance(1)
				return world
			end
			-- Seeded: the in-memory stores hold the listings, so the proof is what player 7 receives.
			local on = run({ studio = true, attributes = { SaleyardsDemoSeed = true } })
			local sync = on:lastSync(7)
			assert(sync.coins == 500 + 108, `{sync.coins} coins: the first settle paid out`)
			assert(#sync.notices == 1 and string.find(sync.notices[1].text, "108 Coins", 1, true))
			assert(#sync.claims == 0)
			assert(#on.errors == 0, on.errors[1])
			-- Never into a real data store, even in Studio with the seed attribute on.
			local realStore = run({
				studio = true,
				attributes = { SaleyardsDemoSeed = true, SaleyardsUseDataStore = true },
			})
			assert(#listingKeys(realStore.records) == 0, "off with a real data store")
			assert(realStore:lastSync(7).coins == 500)
			local notStudio = run({ studio = false, attributes = { SaleyardsDemoSeed = true } })
			assert(#listingKeys(notStudio.records) == 0, "off outside Studio")
			assert(notStudio:lastSync(7).coins == 500)
			local noAttribute = run({ studio = true })
			assert(noAttribute:lastSync(7).coins == 500, "off without the attribute")
		end,
	},
	{
		name = "an unpublished Studio place starts, seeds and browses with in-memory sorted maps",
		run = function()
			local world =
				FakeGame.new({ studio = true, unpublished = true, attributes = { SaleyardsDemoSeed = true } })
			world:start()
			assert(world.started == true, world.startError)
			world:join(7)
			world.sched:advance(1)
			assert(world:lastSync(7).coins == 500 + 108, `{world:lastSync(7).coins} coins: the seed paid out`)
			local page = world:browse(7, "price")
			assert(page ~= nil and #page.entries > 0, "the seeded listings are in the browse page")
			assert(#world:browse(7, "ending").entries > 0)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
}
