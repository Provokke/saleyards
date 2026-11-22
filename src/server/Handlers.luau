--!strict
-- What the client may ask the server for. A factory: everything arrives as a dependency, so the
-- checks can be tested without remotes.
--
-- Clients send intent only: an action name, an item id, a quantity, a kind, a price, a listing id
-- or a bid. Every call is checked with Validate and then the per-player rate limiter before
-- anything else. A call that fails either, arrives while the same player's last call is still
-- running (here or inside Market), or comes from a player with no saveable session, is dropped
-- and counted. A call the rules refuse (cant_afford, not_enough_items and so on) is not counted
-- and logs nothing, as that is an ordinary answer: it goes to the player with the next Sync, which
-- carries the real state.
--
-- Store budget: a call that touches the DataStore (list, buy, bid, cancel) also spends from a
-- second, slower limiter by what it costs the store, so a loop of cheap-looking calls cannot use
-- up the server's write budget. A call over it is answered with "slow_down". Browse is not charged.
--
-- Busy guard: a market call yields (it saves the profile and writes listings). While it does,
-- any other call from that player is dropped, so one player's calls never interleave. The entry
-- script also waits on `busy` before it releases a session on leave or shutdown.
--
-- What Market returns is mapped to one result, { action, ok, reason?, id? }, handed to `sync`:
--   list    id, or nil and "pending" | "not_listed" | the rule that refused
--   buy, bid, cancel   true, or false and the reason, or nil and "pending" (the claim is held
--           and settles later)
-- A call that throws is logged on one line and counted, and the player is still synced.
local Handlers = {}
Handlers.__index = Handlers

export type Result = { action: string, ok: boolean, reason: string?, id: string? }

export type Deps = {
	validate: any, -- the Validate module
	limiter: any, -- a RateLimiter, keyed by UserId
	storeLimiter: any, -- a second RateLimiter for calls that touch the DataStore, keyed by UserId
	storeCost: { [string]: number }, -- what each action spends from storeLimiter
	config: any, -- MinPrice, MaxPrice, MaxQty, ListingHours, BrowsePageSize
	market: any, -- a Market
	index: any, -- an Index, for Browse
	allowed: (userId: number) -> boolean, -- the player has a session that would be saved
	sync: (userId: number, result: Result?) -> (), -- sends one player their current state
	log: (message: string) -> (), -- one line per market call that threw
}

export type Handlers = typeof(setmetatable(
	{} :: { deps: Deps, dropped: number, running: { [number]: boolean } },
	Handlers
))

local ACTIONS: { [string]: boolean } = { list = true, buy = true, bid = true, cancel = true }
local KINDS: { [string]: boolean } = { fixed = true, auction = true }
local SORTS: { [string]: boolean } = { price = true, ending = true }
local MAX_ITEM = 32 -- ConfigCheck holds item ids to the same length
local MAX_KEY = 64 -- a listing id or a sorted map key
local MAX_AMOUNT = 2 ^ 31
local MAX_SORT_KEY = 2 ^ 53

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, dropped = 0, running = {} }, Handlers)
end

local function valid(deps: Deps, action: any, a: any, b: any, c: any, d: any, e: any): boolean
	local v, config = deps.validate, deps.config
	if not (v.isString(action, 16) and v.isOneOf(action, ACTIONS)) then
		return false
	end
	if action == "list" then
		return v.isString(a, MAX_ITEM)
			and #a >= 1
			and v.isInteger(b, 1, config.MaxQty)
			and v.isOneOf(c, KINDS)
			and v.isInteger(d, config.MinPrice, config.MaxPrice)
			and v.isInteger(e, 1, MAX_AMOUNT)
			and table.find(config.ListingHours, e) ~= nil
	end
	if not (v.isString(a, MAX_KEY) and #a >= 1) then
		return false
	end
	if action == "buy" or action == "bid" then
		return v.isInteger(b, 1, MAX_AMOUNT)
	end
	return true -- cancel takes the listing id only
end

-- Whether a market call for this player is still running, here or inside Market.
function Handlers.busy(self: Handlers, userId: number): boolean
	return self.running[userId] == true or self.deps.market:busy(userId) == true
end

local function run(
	deps: Deps,
	userId: number,
	action: string,
	a: any,
	b: any,
	c: any,
	d: any,
	e: any
): Result?
	local market = deps.market
	if action == "list" then
		local id, reason = market:list(userId, a, b, c, d, e)
		if id == nil and reason == "busy" then
			return nil
		end
		return { action = action, ok = id ~= nil, reason = reason, id = id }
	end
	local done, reason
	if action == "buy" then
		done, reason = market:buy(userId, a, b)
	elseif action == "bid" then
		done, reason = market:bid(userId, a, b)
	else
		done, reason = market:cancel(userId, a)
	end
	if done == nil and reason == "busy" then
		return nil
	end
	return { action = action, ok = done == true, reason = reason, id = a }
end

-- One call from a client. Returns nothing and never throws.
function Handlers.handle(self: Handlers, userId: number, action: any, a: any, b: any, c: any, d: any, e: any)
	local deps = self.deps
	local ok = pcall(function()
		if not valid(deps, action, a, b, c, d, e) or not deps.limiter:take(userId) then
			self.dropped += 1
			return
		end
		if not deps.allowed(userId) then
			self.dropped += 1
			return
		end
		if self:busy(userId) then
			-- Another call, or the settle, holds this player's lock: say so rather than go quiet.
			self.dropped += 1
			deps.sync(userId, { action = action, ok = false, reason = "busy" })
			return
		end
		local cost = deps.storeCost[action]
		if cost ~= nil and not deps.storeLimiter:take(userId, cost) then
			-- Too many store operations lately: tell the player rather than go quiet.
			self.dropped += 1
			deps.sync(userId, { action = action, ok = false, reason = "slow_down" })
			return
		end
		self.running[userId] = true
		local done, result = pcall(run, deps, userId, action, a, b, c, d, e)
		self.running[userId] = nil
		if not done then
			self.dropped += 1
			pcall(deps.log, `market call failed for {userId} ({action}): {tostring(result)}`)
			deps.sync(userId, nil)
			return
		end
		if result == nil then
			self.dropped += 1 -- Market was busy with something else for this player
			deps.sync(userId, { action = action, ok = false, reason = "busy" })
			return
		end
		deps.sync(userId, result)
	end)
	if not ok then
		self.dropped += 1
	end
end

-- Browse. One page of open listings, or nil when the call is dropped. The cursor is rebuilt from
-- the two checked fields, so nothing else a client sends reaches the index.
function Handlers.browse(self: Handlers, userId: number, sort: any, after: any): any
	local deps = self.deps
	local v = deps.validate
	local page: any = nil
	local ok = pcall(function()
		local cursor: any = nil
		if after ~= nil then
			if
				type(after) ~= "table"
				or not (v.isString(after.key, MAX_KEY) and #after.key >= 1)
				or not v.isInteger(after.sortKey, 0, MAX_SORT_KEY)
			then
				self.dropped += 1
				return
			end
			cursor = { key = after.key, sortKey = after.sortKey }
		end
		if not v.isOneOf(sort, SORTS) or not deps.limiter:take(userId) then
			self.dropped += 1
			return
		end
		page = deps.index:page(sort, cursor, deps.config.BrowsePageSize)
	end)
	if not ok then
		self.dropped += 1
		return nil
	end
	return page
end

return Handlers
