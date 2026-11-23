--!strict
-- A simulated world: one shared store, two sorted maps and one clock, with any number of simulated
-- servers over them. Each server has its own Faults, handles, profiles and Market, so a restart
-- is a new server that reads only what the store holds.
--
-- Rules the harness keeps so a pass means something:
-- - every server name is used once, and a server's guids start with its name, so ids never
--   collide across servers unless a spec builds that on purpose;
-- - `restart` and `quiesce` mark the old servers dead first (TestProfiles has no lease), so a
--   suspended thread of an old server can never write again;
-- - Coins and claims are counted from the store's records, never from a server's memory;
-- - settling until quiet is bounded, and hitting the bound is a failure that names the claims
--   still held.
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

local World = {}
World.__index = World

World.USERS = { 1, 2, 3, 4 }
World.MAX_ROUNDS = 20

export type Opts = {
	-- Replaces the real settler (a deliberately broken one, for a negative control).
	settler: any?,
	-- Makes every profile save report success without writing (a broken write order).
	skipProfileSave: boolean?,
	-- Gives every handle Roblox's read cache for this many seconds (a stale read is then possible).
	cacheSeconds: number?,
	-- A deliberately wrong server that is right on a clean run: when a listing write raises, it
	-- hands back the stake of the claim it was making, as if the write had not landed.
	rollbackAfterRaise: boolean?,
	-- Seconds added to this server's clock (negative for a server that runs behind).
	skew: number?,
}

export type Server = {
	name: string,
	faults: Faults.Faults,
	market: Market.Market,
	profiles: TestProfiles.TestProfiles,
	index: any,
	logs: { string },
	-- Builds a second Market over this server's own profiles, index and handles but with its own
	-- per-user lock: two calls for one user through the two Markets are what a Market with no
	-- busy guard would let happen.
	newMarket: () -> Market.Market,
	-- Called with the key before each of this server's listing UpdateAsync calls (not counted as a
	-- write). A spec uses it to run another server in the gap, or to park the calling thread.
	gate: ((key: string) -> ())?,
}

export type World = typeof(setmetatable(
	{} :: {
		opts: Opts,
		records: { [string]: any },
		store: FakeDataStore.FakeDataStore,
		clock: FakeClock.FakeClock,
		byPrice: FakeSortedMap.FakeSortedMap,
		byEnding: FakeSortedMap.FakeSortedMap,
		servers: { Server },
		names: { [string]: boolean },
		quiesces: number,
	},
	World
))

local realSettler = Settle.new(Listing)
World.realSettler = realSettler

function World.new(opts: Opts?): World
	local records: { [string]: any } = {}
	local clock = FakeClock.new(1000)
	return setmetatable({
		opts = opts or {},
		records = records,
		store = FakeDataStore.new(records),
		clock = clock,
		byPrice = FakeSortedMap.new(clock),
		byEnding = FakeSortedMap.new(clock),
		servers = {},
		names = {},
		quiesces = 0,
	}, World)
end

-- A fresh server with its own Faults. `name` must be new to this world: it is the guid prefix.
function World.server(self: World, name: string, opts: Opts?): Server
	assert(not self.names[name], "server name used twice, so its guids could collide: " .. name)
	self.names[name] = true
	local o: Opts = opts or self.opts
	local faults = Faults.new()
	local clock = self.clock
	local real = self.store:handle(
		faults,
		if o.cacheSeconds ~= nil then { cacheSeconds = o.cacheSeconds, clock = clock } else nil
	)
	local skew = o.skew or 0
	local now = function(): number
		return clock:now() + skew
	end
	local s = { name = name, faults = faults, logs = {}, gate = nil } :: any
	local log = function(line: string)
		table.insert(s.logs, line)
	end
	local listings = {
		UpdateAsync = function(_: any, key: string, transform: (any) -> any): any
			local gate = s.gate
			if gate ~= nil and not faults.dead then
				gate(key)
			end
			if not o.rollbackAfterRaise then
				return real:UpdateAsync(key, transform)
			end
			local ok, result = pcall(real.UpdateAsync, real, key, transform)
			if ok then
				return result
			end
			if not faults.dead then
				for userId, profile in s.profiles.profiles do
					local claim = profile.claims[string.sub(key, 9)]
					if claim ~= nil and claim.kind == "listing" then
						profile.items[claim.itemId] = (profile.items[claim.itemId] or 0) + claim.qty
						profile.coins += claim.fee or 0
						profile.claims[claim.id] = nil
						s.profiles:save(userId)
					end
				end
			end
			error(result, 0)
		end,
		GetAsync = function(_: any, key: string, options: any?): any
			return real:GetAsync(key, options)
		end,
	}
	s.profiles = TestProfiles.new(real, Config.StartingCoins, Config.StartingItems)
	s.index = Index.new(self.byPrice:handle(faults), self.byEnding:handle(faults), now, log)
	local counter = 0
	local function deps(): Market.Deps
		return {
			listings = listings,
			index = s.index,
			profiles = {
				get = function(userId: number): any
					return s.profiles:get(userId)
				end,
				save = function(userId: number, _: any, undo: (() -> ())?): boolean
					if o.skipProfileSave then
						return true
					end
					return s.profiles:save(userId, undo)
				end,
			},
			now = now,
			guid = function(): string
				counter += 1
				return name .. counter
			end,
			log = log,
			config = Config,
			Listing = Listing,
			settler = o.settler or realSettler,
		}
	end
	s.market = Market.new(deps())
	s.newMarket = function(): Market.Market
		return Market.new(deps())
	end
	table.insert(self.servers, s :: Server)
	return s :: Server
end

-- Stops a server for good: every later call through its handles raises CRASH.
function World.kill(_: World, s: Server)
	s.faults.dead = true
end

-- Kills `old` and builds a fresh server that reads only the store.
function World.restart(self: World, old: Server, name: string, opts: Opts?): Server
	self:kill(old)
	return self:server(name, opts)
end

-- The claims still sitting in the store's profile records, as text ("" when there are none).
function World.held(self: World): string
	local keys: { string } = {}
	for key in self.records do
		if string.sub(key, 1, 8) == "profile/" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, key in keys do
		local ids: { string } = {}
		for id, claim in self.records[key].claims or {} do
			table.insert(ids, `{id} ({claim.kind} on {claim.listingId})`)
		end
		table.sort(ids)
		for _, text in ids do
			table.insert(parts, `{key}: {text}`)
		end
	end
	return table.concat(parts, "; ")
end

-- Moves the clock past every listing's endsAt.
function World.advancePastEnds(self: World)
	local last = 0
	for key, record in self.records do
		if string.sub(key, 1, 8) ~= "profile/" and record.endsAt ~= nil and record.endsAt > last then
			last = record.endsAt
		end
	end
	local now = self.clock:now()
	if now <= last then
		self.clock:advance(last - now + 1)
	end
end

-- Every server is killed (a restart of the whole fleet), the clock is moved past every end, and a
-- fresh server settles every user until a full pass applies nothing. Returns false and a reason
-- when it is still applying after `maxRounds` (default 20), or when a settle was busy or failed to
-- save; the reason names the claims still held in the store.
function World.quiesce(self: World, maxRounds: number?): (boolean, string?)
	local limit = maxRounds or World.MAX_ROUNDS
	for _, s in self.servers do
		self:kill(s)
	end
	self:advancePastEnds()
	self.quiesces += 1
	local q = self:server("Q" .. self.quiesces)
	for round = 1, limit do
		local quiet = true
		for _, userId in World.USERS do
			local applied, saved = q.market:settle(userId)
			if applied == nil then
				return false, `settle for user {userId} answered {tostring(saved)}`
			end
			if applied > 0 or saved ~= true then
				quiet = false
			end
		end
		if quiet then
			return true, nil
		end
		if round == limit then
			return false, `not quiet after {limit} rounds; claims still held: {self:held()}`
		end
	end
	return false, "no rounds ran"
end

-- The conservation check over the store's records.
function World.check(self: World): (boolean, string?)
	local coins: { [number]: number } = {}
	local items: { [number]: { [string]: number } } = {}
	for _, userId in World.USERS do
		coins[userId] = Config.StartingCoins
		items[userId] = Config.StartingItems
	end
	return Conservation.check(self.records, coins, items, Config.SaleTax, self.clock:now())
end

return World
