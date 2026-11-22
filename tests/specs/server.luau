--!strict
-- The server entry script itself, run under Lune over FakeGame: joining and settling, a list and a
-- buy through the remotes, what Sync carries, Browse, and a leave or shutdown that waits for a
-- market call that is still running.
local Config = require("../../src/shared/Config")
local FakeGame = require("../fakes/FakeGame")
local Listing = require("../../src/server/Listing")

local function started(options: any?): any
	local world = FakeGame.new(options)
	world:start()
	assert(world.started == true, world.startError)
	return world
end

local function stored(world: any, userId: number): any
	local record = world.records["Player_" .. userId]
	return if record ~= nil then record.data else nil
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function warned(world: any, text: string): boolean
	for _, line in world.warnings do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

-- A player record that holds one finished listing claim, and the sold listing it points at.
local function withPayout(world: any)
	local l = Listing.create(nil, {
		id = "L1",
		seller = 1,
		itemId = "saddle",
		qty = 1,
		kind = "fixed",
		price = 50,
		fee = 5,
		endsAt = world.clock:now() + 3600,
	}, world.clock:now()) :: any
	l.state = "sold"
	l.buyer = { userId = 2, buyId = "b1" }
	world.records["listing/L1"] = l
	world.records.Player_1 = {
		schema = 1,
		savedAt = 0,
		data = {
			coins = 100,
			items = {},
			claims = {
				c1 = {
					kind = "listing",
					listingId = "L1",
					itemId = "saddle",
					qty = 1,
					amount = 50,
					fee = 5,
					id = "c1",
					at = 900,
				},
			},
			notices = {},
		},
	}
end

return {
	{
		name = "a config that fails its checks refuses to start, with a warning",
		run = function()
			local bad = table.clone(Config)
			bad.MinPrice = 0
			local world = FakeGame.new({ config = bad })
			world:start()
			assert(world.started == true, world.startError)
			assert(world:remote("Request") == nil, "nothing else started")
			assert(warned(world, "MinPrice"), "the problem is warned about")
		end,
	},
	{
		name = "the three remotes are made, and a joining player is synced with the starting profile",
		run = function()
			local world = started()
			assert(world:remote("Request") ~= nil and world:remote("Sync") ~= nil)
			assert(world:remote("Browse") ~= nil and world:remote("Browse").ClassName == "RemoteFunction")
			world:join(1)
			local sync = world:lastSync(1)
			assert(sync ~= nil, "synced")
			assert(sync.coins == 500, tostring(sync.coins))
			assert(sync.items.hay_bale == 6 and sync.items.fleece == 4 and sync.items.horseshoe == 8)
			assert(#sync.claims == 0 and #sync.notices == 0)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a join settles the claims it holds, and the payout reaches the player in a Sync",
		run = function()
			local world = started()
			withPayout(world)
			world:join(1)
			world.sched:advance(1)
			local sync = world:lastSync(1)
			assert(sync.coins == 145, `{sync.coins} coins: 50 less 5 tax`)
			assert(#sync.claims == 0)
			assert(#sync.notices == 1 and string.find(sync.notices[1].text, "45 Coins", 1, true))
			-- the saved profile holds it too, once the player leaves
			world:leave(1)
			world.sched:advance(1)
			local data = stored(world, 1)
			assert(data.coins == 145 and count(data.claims) == 0 and #data.notices == 1)
			assert(world.records["listing/L1"].settled.seller == true, "marked settled")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a list and a buy go through the remotes, each with a Sync, and the seller is paid by the poll",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			local sent = #world.synced
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 6)
			assert(#world.synced == sent + 1, "one Sync for the call")
			local sync = world:lastSync(1)
			assert(sync.result.action == "list" and sync.result.ok == true and sync.result.id ~= nil)
			assert(sync.coins == 500 - Config.ListingFee and sync.items.hay_bale == 4)
			assert(#sync.claims == 1 and sync.claims[1].kind == "listing")
			local id = sync.result.id
			assert(world.records["listing/" .. id].state == "open")

			-- browse sees it
			local page = world:browse(2, "price")
			assert(page ~= nil and #page.entries == 1 and page.entries[1].id == id, "in the browse page")
			assert(world:browse(2, "ending").entries[1].id == id)
			assert(#world:browse(2, "price", { key = id, sortKey = 40 }).entries == 0, "after the cursor")
			assert(world:browse(2, "bogus") == nil, "a bad sort is dropped")

			world:request(2, "buy", id, 40)
			local buyer = world:lastSync(2)
			assert(buyer.result.ok == true and buyer.coins == 460 and buyer.items.hay_bale == 8)
			assert(#buyer.claims == 0)
			assert(world.records["listing/" .. id].state == "sold")

			-- The seller's claim is still held. The poll settles it within SettleSeconds.
			assert(#world:lastSync(1).claims == 1, "not yet")
			world.sched:advance(Config.SettleSeconds + 1)
			local paid = world:lastSync(1)
			assert(paid.coins == 500 - 5 + 36, `{paid.coins} coins`)
			assert(#paid.claims == 0 and #paid.notices == 1)
			assert(string.find(paid.notices[1].text, "36 Coins", 1, true))
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "Sync carries only the notices since the last one",
		run = function()
			local world = started()
			withPayout(world)
			world:join(1)
			world.sched:advance(1)
			assert(#world:lastSync(1).notices == 1)
			world:request(1, "cancel", "nothing-here")
			local sync = world:lastSync(1)
			assert(sync.result.ok == false, "a refusal is reported in the result")
			assert(#sync.notices == 0, "the payout notice is not sent again")
		end,
	},
	{
		name = "bad requests are dropped with no Sync and nothing written",
		run = function()
			local world = started()
			world:join(1)
			local sent = #world.synced
			world:request(1, "list", "hay_bale", 0, "fixed", 40, 6)
			world:request(1, "list", "hay_bale", 1, "fixed", 40, 7)
			world:request(1, "buy", "", 5)
			world:request(1, "sell", "x")
			world:request(1, nil)
			assert(#world.synced == sent, "no Sync for a dropped call")
			for key in world.records do
				assert(string.sub(key, 1, 8) ~= "listing/", "no listing was written")
			end
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a leave waits for a market call that is still running before it saves and releases",
		run = function()
			local world = started()
			world:join(1)
			-- The profile save goes through; the listing write parks, so the call is running
			-- outside the session's own save.
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(5)
			end)
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 6)
			world:leave(1)
			world.sched:advance(2)
			local record = world.records.Player_1
			assert(record.lease ~= nil, "the release is waiting for the call")
			world.sched:advance(10)
			record = world.records.Player_1
			assert(record.lease == nil, "released once the call finished")
			assert(record.data.items.hay_bale == 4, "the saved data holds the finished call")
			assert(count(record.data.claims) == 1)
			local listed = 0
			for key, value in world.records do
				if string.sub(key, 1, 8) == "listing/" and value.state == "open" then
					listed += 1
				end
			end
			assert(listed == 1, "and its listing is on sale")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a call that never finishes does not hold a leave past CloseTimeoutSeconds",
		run = function()
			local world = started()
			world:join(1)
			-- The first store call (the profile save) is left alone. The second (the listing write)
			-- hangs, so the market call is stuck outside the session's own save.
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(1000)
			end)
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 6)
			world:leave(1)
			world.sched:advance(Config.CloseTimeoutSeconds - 1)
			assert(world.records.Player_1.lease ~= nil, "still waiting")
			world.sched:advance(5)
			assert(world.records.Player_1.lease == nil, "released anyway")
			assert(warned(world, "still running"), "and it said so")
		end,
	},
	{
		name = "BindToClose waits for a running market call, then releases every session",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(5)
			end)
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 6)
			assert(world.onClose ~= nil, "BindToClose was used")
			local closed = false
			world.sched:spawn(function()
				world.onClose()
				closed = true
			end)
			world.sched:advance(2)
			assert(closed == false, "still waiting on the call")
			world.sched:advance(10)
			assert(closed == true, "done")
			assert(world.records.Player_1.lease == nil and world.records.Player_2.lease == nil)
			assert(world.records.Player_1.data.items.hay_bale == 4)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a rejoin on a restarted server keeps the claim and settles it",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 6)
			local id = world:lastSync(1).result.id
			world:request(2, "buy", id, 40)
			world:leave(1)
			world:leave(2)
			world.sched:advance(1)
			local again = started({ records = world.records, start = 2000 })
			again:join(1)
			again.sched:advance(1)
			local sync = again:lastSync(1)
			assert(sync.coins == 500 - 5 + 36, `{sync.coins} coins`)
			assert(#sync.claims == 0 and #sync.notices == 1)
			assert(#again.errors == 0, again.errors[1])
		end,
	},
}
