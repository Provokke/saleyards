--!strict
-- Crash at every write. Each scenario is a script of operations on server A. It is run clean to
-- count its writes (n), then once for every write k in 1..n in both modes: "stop" kills A before
-- write k lands, "lost" lets write k land and then raises. After each run every server is
-- restarted, a fresh server settles until quiet, and the store's records must conserve Coins and
-- items. A failure names the scenario, k and the mode.
local process = require("@lune/process")

local Faults = require("../fakes/Faults")
local World = require("../harness/World")

local HOUR = 3600
local verbose = process.env.SALEYARDS_VERBOSE ~= nil

type Step = (fn: () -> ()) -> ()

type Scenario = {
	name: string,
	-- Runs the operations. `step` runs one under pcall and skips the rest once A has crashed.
	run: (w: World.World, a: World.Server, step: Step) -> (),
	-- Checks the records of a clean run after quiesce (nil when it is fine).
	expect: ((records: { [string]: any }) -> string?)?,
	-- True when the clean run writes a close for a listing that is final only by the clock.
	closes: boolean?,
}

local function expectProfile(
	records: { [string]: any },
	userId: number,
	coins: number,
	items: { [string]: number }
): string?
	local p = records["profile/" .. userId]
	if p == nil then
		return `user {userId} has no profile`
	end
	if p.coins ~= coins then
		return `user {userId} holds {p.coins} Coins, expected {coins}`
	end
	for itemId, count in items do
		if (p.items[itemId] or 0) ~= count then
			return `user {userId} holds {p.items[itemId] or 0} {itemId}, expected {count}`
		end
	end
	return nil
end

local function first(...: string?): string?
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil then
			return v
		end
	end
	return nil
end

-- The auction both time-final scenarios share, settled in the given order.
local function auction(settleOrder: { number }): (World.World, World.Server, Step) -> ()
	return function(w, a, step)
		local id: string? = nil
		step(function()
			id = a.market:list(1, "fleece", 1, "auction", 20, 1)
		end)
		step(function()
			if id ~= nil then
				a.market:bid(2, id, 20)
			end
		end)
		step(function()
			if id ~= nil then
				a.market:bid(3, id, 30)
			end
		end)
		step(function()
			w.clock:advance(HOUR + 1)
		end)
		for _, userId in settleOrder do
			step(function()
				a.market:settle(userId)
			end)
		end
	end
end

local function auctionEnd(r: { [string]: any }): string?
	return first(
		expectProfile(r, 1, 522, { fleece = 3 }),
		expectProfile(r, 2, 500, { fleece = 4 }),
		expectProfile(r, 3, 470, { fleece = 5 })
	)
end

local scenarios: { Scenario } = {
	{
		name = "list",
		run = function(_, a, step)
			step(function()
				a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
		end,
		-- Nobody bought, and quiesce runs past the end: the item comes back and the fee does not.
		expect = function(r)
			return expectProfile(r, 1, 495, { hay_bale = 6 })
		end,
	},
	{
		name = "list then buy",
		run = function(_, a, step)
			local id: string? = nil
			step(function()
				id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			step(function()
				if id ~= nil then
					a.market:buy(2, id, 40)
				end
			end)
		end,
		expect = function(r)
			return first(
				expectProfile(r, 1, 531, { hay_bale = 4 }),
				expectProfile(r, 2, 460, { hay_bale = 8 })
			)
		end,
	},
	{
		name = "list then cancel",
		run = function(_, a, step)
			local id: string? = nil
			step(function()
				id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			step(function()
				if id ~= nil then
					a.market:cancel(1, id)
				end
			end)
		end,
		expect = function(r)
			return expectProfile(r, 1, 495, { hay_bale = 6 })
		end,
	},
	{
		-- The listing is final only by the clock: settlement writes the close for a listing claim.
		name = "list, ends unsold, seller settles (close for a listing claim)",
		closes = true,
		run = function(w, a, step)
			step(function()
				a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			step(function()
				w.clock:advance(HOUR + 1)
				a.market:settle(1)
			end)
		end,
		expect = function(r)
			return expectProfile(r, 1, 495, { hay_bale = 6 })
		end,
	},
	{
		name = "auction, two bids, ends, settle 1 2 3 (close for a listing claim)",
		closes = true,
		run = auction({ 1, 2, 3 }),
		expect = auctionEnd,
	},
	{
		name = "auction, two bids, ends, settle 3 2 1 (close for a winning bid claim)",
		closes = true,
		run = auction({ 3, 2, 1 }),
		expect = auctionEnd,
	},
	{
		-- User 2's buy passes the pre-read, then user 3 buys on server B in the gap before A's
		-- listing write, so A's write is refused and its stake has to be voided and refunded.
		name = "buy refused after the stake (stale pre-read) and its refund",
		run = function(w, a, step)
			local id: string? = nil
			step(function()
				id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			step(function()
				if id == nil then
					return
				end
				local listingId = id
				local b = w:server("B")
				a.gate = function(key: string)
					if key == "listing/" .. listingId then
						a.gate = nil
						assert(b.market:buy(3, listingId, 40) == true, "B's buy should win")
					end
				end
				a.market:buy(2, listingId, 40)
			end)
		end,
		expect = function(r)
			return first(
				expectProfile(r, 1, 531, { hay_bale = 4 }),
				expectProfile(r, 2, 500, { hay_bale = 6 }),
				expectProfile(r, 3, 460, { hay_bale = 8 })
			)
		end,
	},
	{
		-- The seller is paid on A for a fixed sale: pay on a sold listing, then markSettled and the
		-- index removes, all of them writes of the live server.
		name = "list, buy, seller settles on A (fixed sale payout)",
		run = function(_, a, step)
			local id: string? = nil
			step(function()
				id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
			end)
			step(function()
				if id ~= nil then
					a.market:buy(2, id, 40)
				end
			end)
			step(function()
				a.market:settle(1)
			end)
		end,
		expect = function(r)
			return first(
				expectProfile(r, 1, 531, { hay_bale = 4 }),
				expectProfile(r, 2, 460, { hay_bale = 8 })
			)
		end,
	},
}

type Failure = { k: number, k2: number?, mode: string, why: string }
type Walk = { name: string, n: number, runs: number, failures: { Failure } }
type Run = {
	writes: number, -- the number of writes A made
	world: World.World,
	quiet: boolean, -- a fresh server settled until quiet
	conserved: boolean, -- the store's records conserve Coins and items
	why: string?, -- the reason when it is not quiet or does not conserve
}

-- stop: A dies before write k lands. lost: write k lands and then raises. fail: write k raises
-- before it lands and A carries on, so the paths a live server takes after a failed request run.
local MODES: { Faults.Mode } = { "stop", "lost", "fail" }

local function merge(base: World.Opts?, extra: World.Opts): World.Opts
	local out: World.Opts = {}
	for key, value in (base or {}) :: any do
		(out :: any)[key] = value
	end
	for key, value in extra :: any do
		(out :: any)[key] = value
	end
	return out
end

-- Runs one scenario on a fresh world. `k` arms server A at its k-th write in `mode`; `k2` (with
-- mode "lost") also loses A's k2-th write. Fails when an armed fault never fired (the run would
-- be a clean one in disguise). Then every server is restarted, a fresh server settles until quiet
-- and the store's records are checked.
local function play(sc: Scenario, opts: World.Opts?, k: number?, mode: Faults.Mode?, k2: number?): Run
	local w = World.new(opts)
	local a = w:server("A")
	if k ~= nil and mode ~= nil then
		if k2 ~= nil then
			a.faults:armPair(k, k2)
		else
			a.faults:arm(k, mode)
		end
	end
	local crashed = false
	local function step(fn: () -> ())
		if crashed then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			if a.faults.dead then
				crashed = true
			else
				error("an operation raised past Market while A was alive: " .. tostring(err), 0)
			end
		end
	end
	sc.run(w, a, step)
	if k ~= nil then
		assert(
			a.faults.target == nil,
			`armed write {k} ({mode}) never fired, A made {a.faults.writes} writes`
		)
		if mode == "stop" then
			assert(a.faults.dead, "a stop did not kill A")
		end
	end
	local writes = a.faults.writes
	local quiet, why = w:quiesce()
	if not quiet then
		return { writes = writes, world = w, quiet = false, conserved = false, why = why }
	end
	local conserved, reason = w:check()
	return { writes = writes, world = w, quiet = true, conserved = conserved, why = reason }
end

-- The clean run first (k = 0), then `armed` is given the write count and a function that makes
-- one armed run, and decides which runs to make.
local function walkWith(
	sc: Scenario,
	opts: World.Opts?,
	armed: (n: number, run: (k: number, mode: Faults.Mode, k2: number?) -> ()) -> ()
): Walk
	local clean = play(sc, opts, nil, nil)
	local out: Walk = { name = sc.name, n = clean.writes, runs = 0, failures = {} }
	if not clean.conserved then
		table.insert(out.failures, { k = 0, mode = "clean", why = tostring(clean.why) })
	elseif sc.expect ~= nil then
		local bad = sc.expect(clean.world.records)
		if bad ~= nil then
			table.insert(out.failures, { k = 0, mode = "clean", why = "unexpected end state: " .. bad })
		end
	end
	armed(clean.writes, function(k: number, mode: Faults.Mode, k2: number?)
		out.runs += 1
		local ran, result = pcall(play, sc, opts, k, mode, k2)
		if not ran then
			table.insert(out.failures, { k = k, k2 = k2, mode = mode, why = tostring(result) })
		else
			local finished = result :: Run
			if not finished.conserved then
				table.insert(out.failures, { k = k, k2 = k2, mode = mode, why = tostring(finished.why) })
			end
		end
	end)
	if verbose then
		print(`crash walk: {sc.name}: n={clean.writes}, runs={out.runs}, failures={#out.failures}`)
	end
	return out
end

-- Every write k in 1..n in every mode.
local function walk(sc: Scenario, opts: World.Opts?): Walk
	return walkWith(sc, opts, function(n, run)
		for k = 1, n do
			for _, mode in MODES do
				run(k, mode, nil)
			end
		end
	end)
end

-- Every pair of lost writes k1 < k2. A lost write that is then read back through a stale cache is
-- what hides a write that landed; losing the next write too is what a settler that trusts a
-- failed void falls for.
local function walkPairs(sc: Scenario, opts: World.Opts?): Walk
	return walkWith(sc, opts, function(n, run)
		for k1 = 1, n - 1 do
			for k2 = k1 + 1, n do
				run(k1, "lost", k2)
			end
		end
	end)
end

local function describe(w: Walk): string
	local lines: { string } = {}
	for _, f in w.failures do
		local at = if f.k2 ~= nil then `{f.k},{f.k2}` else tostring(f.k)
		table.insert(lines, `{w.name} k={at} mode={f.mode}: {f.why}`)
	end
	return table.concat(lines, "\n")
end

-- True when the walk failed at write k in `mode` with a reason that starts with `pattern`.
local function failedAt(w: Walk, k: number, mode: string, pattern: string, k2: number?): boolean
	for _, f in w.failures do
		if f.k == k and f.mode == mode and f.k2 == k2 and string.find(f.why, pattern) ~= nil then
			return true
		end
	end
	return false
end

-- A control has to fail at a real crash point: a failure of the clean run (k = 0) proves nothing
-- about the walk.
local function failsAfterCrash(w: Walk): boolean
	for _, f in w.failures do
		if f.k >= 1 then
			return true
		end
	end
	return false
end

local function cleanRunPassed(w: Walk): boolean
	for _, f in w.failures do
		if f.k == 0 then
			return false
		end
	end
	return true
end

local function byName(prefix: string): Scenario
	for _, sc in scenarios do
		if string.sub(sc.name, 1, #prefix) == prefix then
			return sc
		end
	end
	error("no scenario starts with " .. prefix)
end

local specs: { { name: string, run: () -> () } } = {}

local CACHED: World.Opts = { cacheSeconds = 4 }
local COINS_OR_ITEMS = "^[ci][to][ie][nm]s:" -- "coins:" or "items:"

local function assertWalk(sc: Scenario, result: Walk)
	assert(result.n >= 1, `{sc.name}: the clean run made no writes, so the walk would be empty`)
	assert(
		result.runs == #MODES * result.n,
		`{sc.name}: walk ran {result.runs} times, expected {#MODES * result.n}`
	)
	assert(#result.failures == 0, describe(result))
end

for _, sc in scenarios do
	table.insert(specs, {
		name = "crash every write: " .. sc.name,
		run = function()
			assertWalk(sc, walk(sc, nil))
		end,
	})
	-- Real GetAsync serves a cached read, so a write that landed unseen can leave a stale `open`.
	table.insert(specs, {
		name = "crash every write, read cache on: " .. sc.name,
		run = function()
			assertWalk(sc, walk(sc, CACHED))
		end,
	})
	if sc.closes then
		table.insert(specs, {
			name = "crash every write: the clean run of '" .. sc.name .. "' writes a close",
			run = function()
				local w = World.new()
				local a = w:server("A")
				sc.run(w, a, function(fn: () -> ())
					fn()
				end)
				local ended = 0
				for key, record in w.records do
					if string.sub(key, 1, 8) == "listing/" and record.state == "ended" then
						ended += 1
					end
				end
				assert(ended == 1, "no listing was stored as ended, so settlement made no close write")
			end,
		})
	end
end

-- Two lost writes in one run, for the scenarios where a buy or bid has to be told apart from one
-- that failed on our side.
for _, prefix in { "list then buy", "list, buy,", "auction, two bids, ends, settle 1 2 3" } do
	local sc = byName(prefix)
	table.insert(specs, {
		name = "crash every pair of lost writes, read cache on: " .. sc.name,
		run = function()
			local result = walkPairs(sc, CACHED)
			assert(result.n >= 2)
			assert(
				result.runs == result.n * (result.n - 1) // 2,
				`{sc.name}: pair walk ran {result.runs} times`
			)
			assert(#result.failures == 0, describe(result))
		end,
	})
end

-- Negative controls: the same walks must be able to fail, at a crash point and not only on the
-- clean run.
local real = World.realSettler

-- Right on a clean run, wrong only after a raise.
table.insert(specs, {
	name = "crash control: a server that rolls the stake back after a raised listing write fails the walk",
	run = function()
		for _, sc in scenarios do
			local result = walk(sc, { rollbackAfterRaise = true })
			assert(cleanRunPassed(result), `{sc.name}: the control must be right on a clean run`)
			assert(failsAfterCrash(result), `{sc.name}: the control never failed at a crash point`)
			-- Write 2 is the create (the stake's save is 1): it lands, then raises, and is rolled back.
			assert(
				failedAt(result, 2, "lost", COINS_OR_ITEMS),
				`{sc.name}: no money failure at k=2 lost\n{describe(result)}`
			)
		end
	end,
})

local refundNoVoid: any = {
	decide = function(claim: any, listing: any, now: number, saleTax: number, userId: number): any
		local out = real.decide(claim, listing, now, saleTax, userId)
		if out.action == "void_then_decide" and claim.kind ~= "listing" then
			return { action = "refund", coins = claim.amount }
		end
		return out
	end,
	needsClose = real.needsClose,
}

table.insert(specs, {
	name = "crash control: a settler that refunds without voiding first fails when a write landed unseen",
	run = function()
		local opts = merge(CACHED, { settler = refundNoVoid })
		-- The buy lands but its response is lost; the stake's settle reads the cached `open`.
		local buy = walk(byName("list then buy"), opts)
		assert(cleanRunPassed(buy), describe(buy))
		assert(failedAt(buy, 6, "lost", COINS_OR_ITEMS), describe(buy))
		local seller = walk(byName("list, buy,"), opts)
		assert(cleanRunPassed(seller), describe(seller))
		assert(failedAt(seller, 6, "lost", COINS_OR_ITEMS), describe(seller))
		-- The winning bid is refunded. Write 10 is the second bid: the first bid's settle puts the
		-- auction back in the browse cache (two index writes) before it.
		for _, prefix in { "auction, two bids, ends, settle 1 2 3", "auction, two bids, ends, settle 3 2 1" } do
			local auctionWalk = walk(byName(prefix), opts)
			assert(cleanRunPassed(auctionWalk), describe(auctionWalk))
			assert(failedAt(auctionWalk, 10, "lost", COINS_OR_ITEMS), describe(auctionWalk))
		end
		-- Without the cache the lost write is read back and the control passes: the cache is what
		-- lets the walk see a write that landed unseen.
		local uncached = walk(byName("list then buy"), { settler = refundNoVoid })
		assert(#uncached.failures == 0, describe(uncached))
	end,
})

table.insert(specs, {
	name = "crash control: a settler that refunds without voiding first fails the pair walk",
	run = function()
		local opts = merge(CACHED, { settler = refundNoVoid })
		local buy = walkPairs(byName("list then buy"), opts)
		assert(cleanRunPassed(buy), describe(buy))
		assert(failedAt(buy, 6, "lost", COINS_OR_ITEMS, 7), describe(buy))
		local auctionWalk = walkPairs(byName("auction, two bids, ends, settle 1 2 3"), opts)
		assert(cleanRunPassed(auctionWalk), describe(auctionWalk))
		assert(failedAt(auctionWalk, 10, "lost", COINS_OR_ITEMS, 11), describe(auctionWalk))
	end,
})

table.insert(specs, {
	name = "crash control: a hand-made extra Coin fails the conservation check",
	run = function()
		local run = play(byName("list then buy"), nil, nil, nil)
		assert(run.conserved, run.why)
		run.world.records["profile/2"].coins += 1
		local after, reason = run.world:check()
		assert(not after and string.find(reason or "", "^coins:") ~= nil, tostring(reason))
	end,
})

table.insert(specs, {
	name = "crash control: a hand-made extra item fails the conservation check",
	run = function()
		local run = play(byName("list then buy"), nil, nil, nil)
		assert(run.conserved, run.why)
		run.world.records["profile/2"].items.fleece = (run.world.records["profile/2"].items.fleece or 0) + 1
		local after, reason = run.world:check()
		assert(not after and string.find(reason or "", "^items:") ~= nil, tostring(reason))
	end,
})

table.insert(specs, {
	name = "crash control: a settler that gives a buy claim the item whatever the buyer fails the walk",
	run = function()
		local broken: any = {
			decide = function(claim: any, listing: any, now: number, saleTax: number, userId: number): any
				if claim.kind == "buy" and listing ~= nil and listing.state == "sold" then
					return { action = "give_item" }
				end
				return real.decide(claim, listing, now, saleTax, userId)
			end,
			needsClose = real.needsClose,
		}
		local result = walk(byName("buy refused after the stake"), { settler = broken })
		assert(result.n >= 1 and result.runs == #MODES * result.n)
		assert(failsAfterCrash(result), describe(result))
		local conservation = false
		for _, f in result.failures do
			if f.k >= 1 and string.find(f.why, COINS_OR_ITEMS) ~= nil then
				conservation = true
			end
		end
		assert(conservation, describe(result))
	end,
})

table.insert(specs, {
	name = "crash control: skipping the write-ahead profile save fails the walk after a crash",
	run = function()
		local result = walk(byName("list"), { skipProfileSave = true })
		assert(result.n >= 1 and result.runs == #MODES * result.n)
		assert(failsAfterCrash(result), describe(result))
		-- The create lands with nothing saved behind it, then the response is lost.
		assert(failedAt(result, 1, "lost", COINS_OR_ITEMS), describe(result))
	end,
})

-- Harness self-checks.
table.insert(specs, {
	name = "crash harness: a restarted server's predecessor can no longer write",
	run = function()
		local w = World.new()
		local a = w:server("A")
		local id = a.market:list(1, "hay_bale", 2, "fixed", 40, 1)
		assert(id == "A1")
		local b = w:restart(a, "B")
		assert(a.faults.dead == true)
		local calls = w.store.calls
		local again1, reason = a.market:list(1, "hay_bale", 1, "fixed", 10, 1)
		assert(again1 == nil and reason == "save_failed", "the old server listed after its restart")
		assert(w.store.calls == calls, "the old server's write reached the store")
		assert(b.market:list(1, "hay_bale", 1, "fixed", 10, 1) == "B1", "guids must carry the server name")
		local again = pcall(function()
			w:server("A")
		end)
		assert(not again, "a reused server name would let guids collide")
	end,
})

table.insert(specs, {
	name = "crash harness: quiesce fails at the round bound, and a held claim fails the check",
	run = function()
		local w = World.new()
		local a = w:server("A")
		local id = a.market:list(1, "fleece", 1, "auction", 20, 1)
		assert(id ~= nil)
		assert(a.market:bid(2, id, 20) == true)
		-- The first round applies the claims, so a limit of one round is hit before a quiet pass.
		local ok, why = w:quiesce(1)
		assert(not ok and string.find(why or "", "not quiet after 1 rounds", 1, true) ~= nil, tostring(why))

		local kept: any = {
			decide = function(): any
				return { action = "keep" }
			end,
			needsClose = function(): boolean
				return false
			end,
		}
		local w2 = World.new({ settler = kept })
		local a2 = w2:server("A")
		assert(a2.market:list(1, "hay_bale", 1, "fixed", 10, 1) ~= nil)
		assert(w2:quiesce(), "a settler that keeps everything applies nothing, so it is quiet")
		local conserved, reason = w2:check()
		assert(not conserved and string.find(reason or "", "claims:", 1, true) ~= nil, tostring(reason))
	end,
})

return specs
