--!strict
-- Two servers on one store, racing. Each server's thread parks (on a FakeScheduler) before every
-- listing UpdateAsync, and the two servers wake at different delays, so their writes interleave
-- one for one. Swapping the delays runs the same race in the other order. The order is recorded
-- as each write is released, and the spec asserts the order it asked for really happened.
local FakeScheduler = require("../fakes/FakeScheduler")
local World = require("../harness/World")

type Order = "AB" | "BA"

type Race = {
	-- Builds the listing on A before the race and returns its id.
	setup: (a: World.Server) -> string,
	opsA: (a: World.Server, id: string) -> (),
	opsB: (b: World.Server, id: string) -> (),
}

type Result = {
	w: World.World,
	log: { string },
	id: string,
	quiet: boolean,
	quietWhy: string?,
	conserved: boolean,
	conservedWhy: string?,
}

local function run(race: Race, order: Order, settler: any?): Result
	local w = World.new(if settler ~= nil then { settler = settler } else nil)
	local a, b = w:server("A"), w:server("B")
	local id = race.setup(a)
	local sched = FakeScheduler.new(w.clock)
	local delay = if order == "AB" then { A = 1, B = 1.5 } else { A = 1.5, B = 1 }
	local log: { string } = {}
	for _, s in { a, b } do
		s.gate = function(key: string)
			sched:wait(delay[s.name])
			table.insert(log, s.name .. " " .. key)
		end
	end
	sched:spawn(function()
		race.opsA(a, id)
	end)
	sched:spawn(function()
		race.opsB(b, id)
	end)
	sched:advance(60)
	assert(#sched.sleeping == 0, "a thread is still parked after the race")
	local quiet, quietWhy = w:quiesce()
	local conserved, conservedWhy = false, quietWhy
	if quiet then
		conserved, conservedWhy = w:check()
	end
	return {
		w = w,
		log = log,
		id = id,
		quiet = quiet,
		quietWhy = quietWhy,
		conserved = conserved,
		conservedWhy = conservedWhy,
	}
end

-- Asserts the requested order happened: the first listing write belongs to the server that was
-- meant to go first, and both servers wrote.
local function assertOrder(r: Result, order: Order)
	assert(#r.log >= 2, "the race recorded fewer than two listing writes")
	assert(string.sub(r.log[1], 1, 1) == string.sub(order, 1, 1), `order {order}: first write was {r.log[1]}`)
	local sawA, sawB = false, false
	for _, line in r.log do
		sawA = sawA or string.sub(line, 1, 1) == "A"
		sawB = sawB or string.sub(line, 1, 1) == "B"
	end
	assert(sawA and sawB, "both servers must write to the listing")
end

local function profile(r: Result, userId: number): any
	return r.w.records["profile/" .. userId]
end

local function hay(r: Result, userId: number): number
	return profile(r, userId).items.hay_bale or 0
end

local buyers: Race = {
	setup = function(a)
		return assert(a.market:list(1, "hay_bale", 2, "fixed", 40, 1))
	end,
	opsA = function(a, id)
		a.market:buy(2, id, 40)
	end,
	opsB = function(b, id)
		b.market:buy(3, id, 40)
	end,
}

local cancelVsBuy: Race = {
	setup = buyers.setup,
	opsA = function(a, id)
		a.market:cancel(1, id)
	end,
	opsB = function(b, id)
		b.market:buy(2, id, 40)
	end,
}

-- A hosts users 2 and 4, B hosts user 3 (a user is on one server at a time). The bids interleave
-- one for one in either order; who ends on top depends on the order, so the spec reads the winner
-- from the listing and checks that only that bidder paid.
local bidWar: Race = {
	setup = function(a)
		return assert(a.market:list(1, "fleece", 1, "auction", 20, 1))
	end,
	opsA = function(a, id)
		a.market:bid(2, id, 25)
		a.market:bid(4, id, 45)
	end,
	opsB = function(b, id)
		b.market:bid(3, id, 35)
		b.market:bid(3, id, 60) -- refused as already_high when 3's 35 is still the top bid
	end,
}

-- A Coin or item count that does not add up, as opposed to some other failure of the harness.
local function isConservation(why: string?): boolean
	return string.find(why or "", "^coins:") ~= nil or string.find(why or "", "^items:") ~= nil
end

local function ok(r: Result)
	assert(r.quiet, r.quietWhy)
	assert(r.conserved, r.conservedWhy)
end

-- Settlers that are wrong in one specific way, each paired with the race that exposes it.
local real = World.realSettler

local function broken(
	decide: (claim: any, listing: any, now: number, saleTax: number, userId: number) -> any?
): any
	return {
		decide = function(claim: any, listing: any, now: number, saleTax: number, userId: number): any
			return decide(claim, listing, now, saleTax, userId)
				or real.decide(claim, listing, now, saleTax, userId)
		end,
		needsClose = real.needsClose,
	}
end

-- A buy claim wins whenever the listing is sold, whoever bought.
local anyBuyerWins = broken(function(claim, listing)
	if claim.kind == "buy" and listing ~= nil and listing.state == "sold" then
		return { action = "give_item" }
	end
	return nil
end)

-- A seller is handed the item back even when it sold.
local sellerAlwaysReturned = broken(function(claim, listing)
	if claim.kind == "listing" and listing ~= nil and listing.state == "sold" then
		return { action = "return_item", refundFee = false }
	end
	return nil
end)

-- Every bid claim wins once the listing is over, whether or not it was the highest.
local everyBidWins = broken(function(claim, listing, now)
	if claim.kind == "bid" and listing ~= nil and now >= listing.endsAt then
		return { action = "give_item" }
	end
	return nil
end)

local specs: { { name: string, run: () -> () } } = {}

for _, order in { "AB", "BA" :: Order } do
	local o: Order = order :: Order
	table.insert(specs, {
		name = `race {o}: two buyers, one listing: one gets the items, the other is refunded in full`,
		run = function()
			local r = run(buyers, o)
			assertOrder(r, o)
			ok(r)
			local winner, loser = if o == "AB" then 2 else 3, if o == "AB" then 3 else 2
			assert(hay(r, winner) == 8 and profile(r, winner).coins == 460)
			assert(hay(r, loser) == 6 and profile(r, loser).coins == 500)
			assert(profile(r, 1).coins == 500 - 5 + 36 and hay(r, 1) == 4)
		end,
	})
	table.insert(specs, {
		name = `race {o}: cancel against buy: exactly one wins`,
		run = function()
			local r = run(cancelVsBuy, o)
			assertOrder(r, o)
			ok(r)
			if o == "AB" then -- the cancel wrote first
				assert(r.w.records["listing/" .. r.id].state == "cancelled")
				assert(profile(r, 2).coins == 500 and hay(r, 2) == 6)
				assert(profile(r, 1).coins == 495 and hay(r, 1) == 6)
			else -- the buy wrote first
				assert(r.w.records["listing/" .. r.id].state == "sold")
				assert(profile(r, 2).coins == 460 and hay(r, 2) == 8)
				assert(profile(r, 1).coins == 531 and hay(r, 1) == 4)
			end
		end,
	})
	table.insert(specs, {
		name = `race {o}: bid war across servers: only the highest bidder has paid`,
		run = function()
			local r = run(bidWar, o)
			assertOrder(r, o)
			ok(r)
			local high = r.w.records["listing/" .. r.id].high
			assert(high ~= nil and high.amount >= 45, "the race should end with a bid of 45 or more")
			for _, userId in { 2, 3, 4 } do
				local p = profile(r, userId)
				if userId == high.userId then
					assert(
						p.coins == 500 - high.amount and p.items.fleece == 5,
						`winner {userId} did not pay once`
					)
				else
					assert(p.coins == 500 and p.items.fleece == 4, `user {userId} was not refunded in full`)
				end
			end
			assert(profile(r, 1).coins == 500 - 5 + high.amount - math.floor(high.amount * 0.1))
		end,
	})
	-- Negative controls: each broken settler must fail the same check in at least this order.
	table.insert(specs, {
		name = `race control {o}: a settler that lets any buyer win fails conservation`,
		run = function()
			local r = run(buyers, o, anyBuyerWins)
			assertOrder(r, o)
			assert(r.quiet and not r.conserved, "the broken settler passed")
			assert(isConservation(r.conservedWhy), tostring(r.conservedWhy))
		end,
	})
	table.insert(specs, {
		name = `race control {o}: a settler that returns a sold item to the seller fails when the buy wins`,
		run = function()
			local r = run(cancelVsBuy, o, sellerAlwaysReturned)
			assertOrder(r, o)
			assert(r.quiet)
			if o == "BA" then -- the buy wrote first, so the seller is wrongly given the item back
				assert(not r.conserved and isConservation(r.conservedWhy), tostring(r.conservedWhy))
			else -- the cancel won, so this settler is right and passes: the control is the other order
				assert(r.conserved, r.conservedWhy)
			end
		end,
	})
	table.insert(specs, {
		name = `race control {o}: a settler that lets every bid win fails conservation`,
		run = function()
			local r = run(bidWar, o, everyBidWins)
			assertOrder(r, o)
			assert(r.quiet and not r.conserved, "the broken settler passed")
			assert(isConservation(r.conservedWhy), tostring(r.conservedWhy))
		end,
	})
end

table.insert(specs, {
	name = "race control: a hand-made extra Coin after a race fails the check",
	run = function()
		local r = run(buyers, "AB")
		ok(r)
		profile(r, 3).coins += 1
		local after, why = r.w:check()
		assert(not after and string.find(why or "", "^coins:") ~= nil, tostring(why))
	end,
})

-- One user, two calls at once on one server. User 2 is outbid, so its bid claim is to be refunded;
-- the poll loop and a join (or an operation's own settle) both settle user 2 while the first is
-- parked at its void write. The per-user lock has to turn the second away: with two Markets
-- standing in for "no lock", user 2 is refunded twice.
local function sameUserSettles(unguarded: boolean): (Result, { any })
	local w = World.new()
	local a = w:server("A")
	local id = assert(a.market:list(1, "fleece", 1, "auction", 20, 1))
	assert(a.market:bid(2, id, 20) == true)
	assert(a.market:bid(3, id, 30) == true)
	local sched = FakeScheduler.new(w.clock)
	local parked = 0
	a.gate = function()
		parked += 1
		sched:wait(1)
	end
	local other = if unguarded then a.newMarket() else a.market
	local answers: { any } = {}
	sched:spawn(function()
		answers[1] = { a.market:settle(2) }
	end)
	sched:spawn(function()
		answers[2] = { other:settle(2) }
	end)
	sched:advance(60)
	a.gate = nil
	assert(#sched.sleeping == 0, "a thread is still parked after the race")
	assert(parked >= 1, "the first settle never reached a listing write, so nothing was in flight")
	local quiet, quietWhy = w:quiesce()
	local conserved, conservedWhy = false, quietWhy
	if quiet then
		conserved, conservedWhy = w:check()
	end
	return {
		w = w,
		log = {},
		id = id,
		quiet = quiet,
		quietWhy = quietWhy,
		conserved = conserved,
		conservedWhy = conservedWhy,
	},
		answers
end

table.insert(specs, {
	name = "race: two settles for one user on one server: the second is turned away and the refund is paid once",
	run = function()
		local r, answers = sameUserSettles(false)
		ok(r)
		assert(answers[1][1] ~= nil, "the first settle should run")
		assert(
			answers[2][1] == nil and answers[2][2] == "busy",
			`the second settle was not turned away: {tostring(answers[2][1])} {tostring(answers[2][2])}`
		)
		assert(profile(r, 2).coins == 500 and profile(r, 2).items.fleece == 4, "user 2 was not refunded once")
		assert(profile(r, 3).coins == 470 and profile(r, 3).items.fleece == 5)
	end,
})

table.insert(specs, {
	name = "race control: with no per-user lock the same two settles refund user 2 twice and fail conservation",
	run = function()
		local r, answers = sameUserSettles(true)
		assert(r.quiet, r.quietWhy)
		assert(answers[2][1] ~= nil, "the second settle was turned away, so there was no lock to remove")
		assert(
			not r.conserved and string.find(r.conservedWhy or "", "^coins:") ~= nil,
			tostring(r.conservedWhy)
		)
	end,
})

-- A server whose clock is ahead refuses a bid once its own time passes the end, even while the
-- listing is still open in the store and another server's clock is behind the end. The bidder
-- keeps every Coin, and the bid that was taken in time wins.
table.insert(specs, {
	name = "race: a server whose clock is ahead refuses a bid at the end and the bidder is not charged",
	run = function()
		local w = World.new()
		local a = w:server("A")
		local fast = w:server("F", { skew = 2 })
		local id = assert(a.market:list(1, "fleece", 1, "auction", 20, 1))
		w.clock:advance(3600 - 1) -- A is one second short of the end, F is one second past it
		assert(a.market:bid(4, id, 25) == true)
		local taken, why = fast.market:bid(3, id, 30)
		assert(
			taken == false and why == "ended",
			`the fast server took the bid: {tostring(taken)} {tostring(why)}`
		)
		local quiet, quietWhy = w:quiesce()
		assert(quiet, quietWhy)
		local conserved, conservedWhy = w:check()
		assert(conserved, conservedWhy)
		-- Refused before anything was staked, so user 3 was never even saved.
		assert(w.records["profile/3"] == nil, "user 3 was charged something")
		assert(w.records["profile/4"].coins == 475 and w.records["profile/4"].items.fleece == 5)
		assert(w.records["listing/" .. id].high.userId == 4)
	end,
})

return specs
