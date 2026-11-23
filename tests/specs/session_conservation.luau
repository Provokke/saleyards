--!strict
-- Conservation through the real session layer: the server entry script (so the real Sessions,
-- Store, Lease and Market) runs over FakeGame, and every case ends the same way. A fresh server
-- starts over the stored records long after every lease and listing has expired, each player joins
-- so their claims settle, and Conservation counts every Coin and item from what is stored. The
-- crash walks run Market over a simpler profile layer; these are the cases that need leases, leave
-- and rejoin, release and shutdown.
local Config = require("../../src/shared/Config")
local Conservation = require("../fakes/Conservation")
local FakeGame = require("../fakes/FakeGame")

local USERS = { 1, 2 }
local RESTART_AT = 50000 -- after every lease (180 s) and one hour listing (3600 s) has run out

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

-- The first listing key in the store.
local function listingKey(world: any): string
	for key in world.records do
		if string.sub(key, 1, 8) == "listing/" then
			return key
		end
	end
	error("no listing was written")
end

-- Seller 2 lists one hay bale for an hour (at 50 fixed, or an auction from 20) and goes offline.
-- Returns the listing id.
local function sellerLists(world: any, kind: string?): string
	world:join(2)
	world.sched:advance(1)
	world:request(2, "list", "hay_bale", 1, kind or "fixed", if kind == "auction" then 20 else 50, 1)
	world.sched:advance(1)
	local id = world:lastSync(2).result.id
	assert(id ~= nil, "listed")
	world:leave(2)
	world.sched:advance(5)
	return id
end

-- The stored records as Conservation reads them: a player's data under profile/<id>, listings as
-- they are.
local function audited(records: any): any
	local out: any = {}
	for key, record in records do
		local id = string.match(key, "^Player_(%d+)$")
		if id ~= nil then
			out["profile/" .. id] = record.data
		else
			out[key] = record
		end
	end
	return out
end

-- Restarts a server over the stored records, has every player join and settle, and counts. Returns
-- the restarted server.
local function settledAndCounted(world: any): any
	local after = started({ records = world.records, start = RESTART_AT, server = "after-" })
	for _, userId in USERS do
		after:join(userId)
	end
	after.sched:advance(Config.SettleSeconds * 3)
	for _, userId in USERS do
		after:leave(userId)
	end
	after.sched:advance(5)
	assert(#after.errors == 0, after.errors[1])
	local startItems: any = {}
	local startCoins: any = {}
	for _, userId in USERS do
		startCoins[userId] = Config.StartingCoins
		startItems[userId] = Config.StartingItems
	end
	local ok, reason =
		Conservation.check(audited(after.records), startCoins, startItems, Config.SaleTax, after.clock:now())
	assert(ok, reason)
	return after
end

-- Runs fn the next time the world's store is read (once), so a read can be parked mid-call.
local function parkNextRead(world: any, seconds: number)
	local armed = true
	world.faults.onRead = function()
		if armed then
			armed = false
			world.sched:wait(seconds)
		end
	end
end

return {
	{
		-- C1. The pre-read of a buy waits while the buyer leaves and rejoins the same server. The
		-- call used to stake into the old session's table and save the new session, making 50
		-- Coins and losing the item.
		name = "a buyer who leaves and rejoins while a buy waits on its first read keeps every Coin and item",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			parkNextRead(world, 60)
			world:request(1, "buy", id, 50)
			world:leave(1)
			world.sched:advance(Config.CloseTimeoutSeconds + 3) -- the release gives up waiting and lands
			assert(world.records.Player_1.lease == nil, "released")
			world:join(1) -- the same server, a new session
			world.sched:advance(2)
			assert(world.records.Player_1.lease ~= nil, "rejoined with a live lease")
			world.sched:advance(60) -- the read comes back
			local live = world.records.Player_1.data
			assert(live.coins == 500 and live.items.hay_bale == 6, "nothing was taken from the new session")
			assert(count(live.claims) == 0, "and no claim was recorded")
			assert(world.records[listingKey(world)].state == "open", "the listing was not bought")
			local sync = world:lastSync(1)
			assert(sync.result.action == "buy" and sync.result.ok == false)
			assert(sync.result.reason == "no_profile", tostring(sync.result.reason))
			world:leave(1)
			world.sched:advance(2)
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world)
		end,
	},
	{
		name = "the same leave and rejoin during a bid's first read keeps every Coin and item",
		run = function()
			local world = started()
			local id = sellerLists(world, "auction")
			world:join(1)
			world.sched:advance(1)
			parkNextRead(world, 60)
			world:request(1, "bid", id, 20)
			world:leave(1)
			world.sched:advance(Config.CloseTimeoutSeconds + 3)
			world:join(1)
			world.sched:advance(2)
			world.sched:advance(60)
			local live = world.records.Player_1.data
			assert(live.coins == 500 and count(live.claims) == 0, "nothing staked")
			assert(world.records[listingKey(world)].high == nil, "and no bid was placed")
			world:leave(1)
			world.sched:advance(2)
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world)
		end,
	},
	{
		-- The leave and rejoin lands in the settle's read instead: the new session still holds the
		-- claim and settles it, and the old call's settle must not save or mark anything for it.
		name = "a leave and rejoin while a buy's own settle reads leaves the claim to the new session",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			local reads = 0
			world.faults.onRead = function()
				reads += 1
				if reads == 2 then -- the pre-read is the first; the settle's read is the second
					world.sched:wait(60)
				end
			end
			world:request(1, "buy", id, 50)
			world:leave(1)
			world.sched:advance(Config.CloseTimeoutSeconds + 3)
			world:join(1)
			world.sched:advance(2)
			local held = world.records.Player_1.data
			assert(held.coins == 450 and count(held.claims) == 1, "the release kept the staked claim")
			world.sched:advance(60)
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(Config.SettleSeconds + 2)
			settledAndCounted(world)
		end,
	},
	{
		-- A seller's settle parks on its read while they leave and rejoin. The old settle applies
		-- the sale to the dead session and must not save the new one, so it must not mark the
		-- listing settled or drop it from the index; the new session settles it later itself.
		name = "a settle that outlives its session writes nothing for the player's new session",
		run = function()
			local world = started()
			world:join(2)
			world.sched:advance(1)
			world:request(2, "list", "hay_bale", 1, "fixed", 50, 1)
			world.sched:advance(1)
			local id = world:lastSync(2).result.id
			world:join(1)
			world.sched:advance(1)
			world:request(1, "buy", id, 50)
			assert(world.records["listing/" .. id].state == "sold", "bought")
			parkNextRead(world, 40)
			world.sched:advance(Config.SettleSeconds + 1) -- the poll starts the seller's settle, which parks
			world:leave(2)
			world.sched:advance(Config.CloseTimeoutSeconds + 3)
			world:join(2)
			world.sched:advance(2)
			world.sched:advance(10) -- the old settle's read returns, before the next poll
			assert(warned(world, "settle save failed for 2"), "the old settle's save was refused")
			assert(world.records["listing/" .. id].settled.seller ~= true, "and nothing was marked settled")
			assert(count(stored(world, 2).claims) == 1, "the claim is still held for the new session")
			world.sched:advance(Config.SettleSeconds + 2) -- the poll settles it for the new session
			assert(world.records["listing/" .. id].settled.seller == true, "now it is marked")
			world:leave(1)
			world:leave(2)
			world.sched:advance(2)
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world)
		end,
	},
	{
		-- Another server takes the lease once it has expired while this one's buy waits on its
		-- first read. The late stake is refused by the lease check, and nothing is lost.
		name = "a lease stolen after it expired, with a buy in flight on the old server, conserves",
		run = function()
			local world = started({ server = "a-" })
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			parkNextRead(world, 1000)
			world:request(1, "buy", id, 50)
			-- The old server stands still while another starts, past the lease, and takes the player.
			local other = started({ records = world.records, start = world.clock:now() + 400, server = "b-" })
			other:join(1)
			other.sched:advance(2)
			assert(other.records.Player_1.lease ~= nil and other:lastSync(1) ~= nil, "taken over")
			other:leave(1)
			other.sched:advance(2)
			-- Now the old server's call carries on, with a session that has lost its lease.
			world.sched:advance(1000)
			assert(
				world.records["listing/" .. id] ~= nil and world.records[listingKey(world)].state == "open"
			)
			local data = stored(world, 1)
			assert(data.coins == 500 and count(data.claims) == 0, "nothing staked for the old server")
			settledAndCounted(world)
		end,
	},
	{
		-- The same takeover with the buy past its stake: the old server's listing write is parked,
		-- the new server settles the claim (the listing has no buyer, so it is voided and refunded)
		-- and the old write then lands late against the voided listing.
		name = "a lease stolen after expiry, with the listing write in flight, voids and refunds the claim",
		run = function()
			local world = started({ server = "a-" })
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function() end) -- the stake's profile save goes through
			world.ds:hookNext(function() -- the listing write parks
				world.sched:wait(1000)
			end)
			world:request(1, "buy", id, 50)
			assert(count(stored(world, 1).claims) == 1 and stored(world, 1).coins == 450, "staked")
			local other = started({ records = world.records, start = world.clock:now() + 400, server = "b-" })
			other:join(1)
			other.sched:advance(Config.SettleSeconds + 2)
			assert(stored(other, 1) ~= nil)
			other:leave(1)
			other.sched:advance(2)
			world.sched:advance(1000) -- the parked write lands, late
			local listing = world.records["listing/" .. id]
			assert(
				listing.state == "open" or listing.buyer == nil or listing.buyer.userId ~= 1,
				"not sold to 1"
			)
			settledAndCounted(world)
		end,
	},
	{
		name = "a leave while a market call is in flight waits for it, saves its result and conserves",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(5)
			end)
			world:request(1, "buy", id, 50)
			world:leave(1)
			world.sched:advance(20)
			assert(world.records.Player_1.lease == nil, "released after the call")
			assert(world.records[listingKey(world)].state == "sold")
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world)
		end,
	},
	{
		-- The write outlasts the wait, so the release lands with the claim and without the sale; the
		-- write then lands behind it.
		name = "a leave while a listing write outlasts the wait still conserves once the write lands",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(40)
			end)
			world:request(1, "buy", id, 50)
			world:leave(1)
			world.sched:advance(Config.CloseTimeoutSeconds + 3)
			local released = world.records.Player_1
			assert(released.lease == nil and count(released.data.claims) == 1, "released holding the claim")
			world.sched:advance(30) -- the write lands behind the release
			assert(world.records[listingKey(world)].state == "sold", "and the listing sold")
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world)
		end,
	},
	{
		name = "a shutdown with a hung listing write releases within the timeout and conserves",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(100000)
			end)
			world:request(1, "buy", id, 50)
			local closed = false
			world.sched:spawn(function()
				world.onClose()
				closed = true
			end)
			world.sched:advance(Config.CloseTimeoutSeconds + 2)
			assert(closed, "BindToClose returned within the timeout")
			local record = world.records.Player_1
			assert(record.lease == nil, "the release landed")
			assert(count(record.data.claims) == 1 and record.data.coins == 450, "holding the stake")
			-- The server is gone: nothing more of it runs. The stored claim refunds on restart.
			settledAndCounted(world)
		end,
	},
	{
		name = "a shutdown with a hung profile save conserves",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function()
				world.sched:wait(100000)
			end)
			world:request(1, "buy", id, 50)
			world.sched:spawn(function()
				world.onClose()
			end)
			world.sched:advance(Config.CloseTimeoutSeconds + 2)
			local data = stored(world, 1)
			assert(data.coins == 500 and count(data.claims) == 0, "the hung save never landed")
			assert(world.records[listingKey(world)].state == "open", "and nothing was written for it")
			settledAndCounted(world)
		end,
	},
	{
		-- A hung market call must not use the whole shutdown timeout: part of it is kept for the
		-- release itself, which then lands inside the timeout.
		name = "a shutdown keeps part of its timeout for the release when a market call hangs",
		run = function()
			local world = started()
			world:join(1)
			world.ds:hookNext(function() end)
			world.ds:hookNext(function()
				world.sched:wait(100000)
			end)
			world:request(1, "list", "hay_bale", 2, "fixed", 40, 1)
			world.sched:spawn(function()
				world.onClose()
			end)
			world.sched:advance(Config.CloseTimeoutSeconds - 1)
			assert(world.records.Player_1.lease == nil, "released before the timeout ran out")
			assert(warned(world, "still running"))
		end,
	},
	{
		-- The stake's save parks for 70 s, so the 60 s autosave queues behind it; the save then fails.
		-- The autosave must not run before the stake is rolled back, or it stores a stake the player
		-- was told did not save.
		name = "an autosave queued behind a failing list save does not store the stake before it is rolled back",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(2)
			world.ds:hookNext(function()
				world.sched:wait(70)
				error("the write failed")
			end)
			world:request(1, "list", "hay_bale", 1, "fixed", 50, 1)
			world.sched:advance(71)
			assert(world:lastSync(1).result.reason == "save_failed", "told it failed")
			local data = stored(world, 1)
			assert(data.coins == Config.StartingCoins, `the autosave stored the listing fee: {data.coins}`)
			assert(data.items.hay_bale == 6 and count(data.claims) == 0, "the item and claim were stored")
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(5)
			settledAndCounted(world)
		end,
	},
	{
		name = "an autosave queued behind a failing buy save does not store the stake before it is rolled back",
		run = function()
			local world = started()
			local id = sellerLists(world)
			world:join(1)
			world.sched:advance(1)
			world.ds:hookNext(function()
				world.sched:wait(70)
				error("the write failed")
			end)
			world:request(1, "buy", id, 50)
			world.sched:advance(71)
			assert(world:lastSync(1).result.reason == "save_failed", "told it failed")
			local data = stored(world, 1)
			assert(data.coins == Config.StartingCoins, `the autosave stored the buy's Coins: {data.coins}`)
			assert(count(data.claims) == 0, "a claim was stored")
			assert(world.records[listingKey(world)].state == "open", "the listing was not bought")
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(5)
			settledAndCounted(world)
		end,
	},
}
