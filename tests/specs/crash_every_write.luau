--!strict
-- Crash at every write. Each scenario is a script of operations on server A. It is run clean to
-- count its writes (n), then once for every write k in 1..n in both modes: "stop" kills A before
-- write k lands, "lost" lets write k land and then raises. After each run every server is
-- restarted, a fresh server settles until quiet, and the store's records must conserve Coins and
-- items. A failure names the scenario, k and the mode.
local process = require("@lune/process")

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
}

type Failure = { k: number, mode: string, why: string }
type Walk = { name: string, n: number, runs: number, failures: { Failure } }

-- Runs one scenario on a fresh world, arming server A at write k in `mode` (or not at all when k
-- is nil). Returns the number of writes A made, the world, and the result of the conservation
-- check after a restart and quiesce.
local function play(
	sc: Scenario,
	opts: World.Opts?,
	k: number?,
	mode: string?
): (number, World.World, boolean, string?)
	local w = World.new(1, opts)
	local a = w:server("A")
	if k ~= nil and mode ~= nil then
		a.faults:arm(k, mode :: any)
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
	local writes = a.faults.writes
	local quiet, why = w:quiesce()
	if not quiet then
		return writes, w, false, why
	end
	local conserved, reason = w:check()
	return writes, w, conserved, reason
end

local function walk(sc: Scenario, opts: World.Opts?): Walk
	local n, cleanWorld, cleanOk, cleanWhy = play(sc, opts, nil, nil)
	local out: Walk = { name = sc.name, n = n, runs = 0, failures = {} }
	if not cleanOk then
		table.insert(out.failures, { k = 0, mode = "clean", why = tostring(cleanWhy) })
	elseif sc.expect ~= nil then
		local bad = sc.expect(cleanWorld.records)
		if bad ~= nil then
			table.insert(out.failures, { k = 0, mode = "clean", why = "unexpected end state: " .. bad })
		end
	end
	for k = 1, n do
		for _, mode in { "stop", "lost" } do
			out.runs += 1
			local ran, _, conserved, why = pcall(play, sc, opts, k, mode)
			if not ran then
				table.insert(out.failures, { k = k, mode = mode, why = tostring(_) })
			elseif not conserved then
				table.insert(out.failures, { k = k, mode = mode, why = tostring(why) })
			end
		end
	end
	if verbose then
		print(`crash walk: {sc.name}: n={n}, runs={out.runs}, failures={#out.failures}`)
	end
	return out
end

local function describe(w: Walk): string
	local lines: { string } = {}
	for _, f in w.failures do
		table.insert(lines, `{w.name} k={f.k} mode={f.mode}: {f.why}`)
	end
	return table.concat(lines, "\n")
end

local specs: { { name: string, run: () -> () } } = {}

for _, sc in scenarios do
	table.insert(specs, {
		name = "crash every write: " .. sc.name,
		run = function()
			local result = walk(sc, nil)
			assert(result.n >= 1, `{sc.name}: the clean run made no writes, so the walk would be empty`)
			assert(
				result.runs == 2 * result.n,
				`{sc.name}: walk ran {result.runs} times, expected {2 * result.n}`
			)
			assert(#result.failures == 0, describe(result))
		end,
	})
	if sc.closes then
		table.insert(specs, {
			name = "crash every write: the clean run of '" .. sc.name .. "' writes a close",
			run = function()
				local w = World.new(1)
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

-- Negative controls: the same walk must be able to fail.
table.insert(specs, {
	name = "crash control: a hand-made extra Coin fails the conservation check",
	run = function()
		local _, w, ok, why = play(scenarios[2], nil, nil, nil)
		assert(ok, why)
		w.records["profile/2"].coins += 1
		local after, reason = w:check()
		assert(not after and string.find(reason or "", "^coins:") ~= nil, tostring(reason))
	end,
})

table.insert(specs, {
	name = "crash control: a hand-made extra item fails the conservation check",
	run = function()
		local _, w, ok, why = play(scenarios[2], nil, nil, nil)
		assert(ok, why)
		w.records["profile/2"].items.fleece = (w.records["profile/2"].items.fleece or 0) + 1
		local after, reason = w:check()
		assert(not after and string.find(reason or "", "^items:") ~= nil, tostring(reason))
	end,
})

table.insert(specs, {
	name = "crash control: a settler that gives a buy claim the item whatever the buyer fails the walk",
	run = function()
		local real = World.realSettler
		local broken: any = {
			decide = function(claim: any, listing: any, now: number, saleTax: number, userId: number): any
				if claim.kind == "buy" and listing ~= nil and listing.state == "sold" then
					return { action = "give_item" }
				end
				return real.decide(claim, listing, now, saleTax, userId)
			end,
			needsClose = real.needsClose,
		}
		local result = walk(scenarios[7], { settler = broken })
		assert(result.n >= 1 and result.runs == 2 * result.n)
		assert(#result.failures > 0, "the broken settler passed the walk, so the walk cannot fail")
		local conservation = false
		for _, f in result.failures do
			if
				string.find(f.why, "items:", 1, true) ~= nil
				or string.find(f.why, "coins:", 1, true) ~= nil
			then
				conservation = true
			end
		end
		assert(conservation, describe(result))
	end,
})

table.insert(specs, {
	name = "crash control: skipping the write-ahead profile save fails the walk",
	run = function()
		local result = walk(scenarios[1], { skipProfileSave = true })
		assert(result.n >= 1 and result.runs == 2 * result.n)
		assert(#result.failures > 0, "an unsaved stake passed the walk, so the walk cannot fail")
	end,
})

-- Harness self-checks.
table.insert(specs, {
	name = "crash harness: a restarted server's predecessor can no longer write",
	run = function()
		local w = World.new(1)
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
		local w = World.new(1)
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
		local w2 = World.new(1, { settler = kept })
		local a2 = w2:server("A")
		assert(a2.market:list(1, "hay_bale", 1, "fixed", 10, 1) ~= nil)
		assert(w2:quiesce(), "a settler that keeps everything applies nothing, so it is quiet")
		local conserved, reason = w2:check()
		assert(not conserved and string.find(reason or "", "claims:", 1, true) ~= nil, tostring(reason))
	end,
})

return specs
