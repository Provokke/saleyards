--!strict
-- Studio-only demo data, so a play test opens on a busy market. The entry script calls it only
-- when RunService:IsStudio() and the ServerStorage attribute SaleyardsDemoSeed is true.
--
-- Every listing is written through `Listing.create` inside UpdateAsync, like any other. The ids
-- are fixed ("demo-1" and so on), so seeding the same store twice refuses the second write
-- ("exists") instead of making duplicates.
--
-- With a playerUserId it also makes a listing of theirs that has already sold (to buyer 105),
-- and hands back the matching claim. The entry script puts that claim into the player's profile
-- as their session goes live and before the first settle, so the first settle shows a payout
-- notice. Nothing here touches a service or requires a module: the Listing module and the item
-- ids come in through `env`.
local DemoSeed = {}

export type Env = {
	Listing: any, -- the Listing module
	items: { string }, -- item ids to list, in order
	fee: number, -- the listing fee recorded on each listing
}

export type Result = {
	ids: { string }, -- every listing written
	claim: any?, -- the claim for the player's pre-sold listing
}

local HOUR = 3600
local DEMO_BUYER = 105
local SOLD_PRICE = 120
local SOLD_QTY = 3

-- fixed or auction, quantity, price or start bid, hours, seller slot
local PLAN = {
	{ kind = "fixed", qty = 4, price = 60, hours = 6 },
	{ kind = "auction", qty = 2, price = 40, hours = 1 },
	{ kind = "fixed", qty = 1, price = 250, hours = 24 },
	{ kind = "auction", qty = 6, price = 15, hours = 24 },
	{ kind = "fixed", qty = 10, price = 8, hours = 6 },
	{ kind = "auction", qty = 1, price = 500, hours = 6 },
}

local function write(listings: any, Listing: any, id: string, fields: any, now: number, sold: boolean): any
	local created: any = nil
	local ok, err = pcall(function()
		listings:UpdateAsync("listing/" .. id, function(current: any)
			local new = Listing.create(current, fields, now)
			if new ~= nil and sold then
				new.state = "sold"
				new.buyer = { userId = DEMO_BUYER, buyId = "demo-buy-" .. id }
			end
			created = new
			return new
		end)
	end)
	if not ok then
		error(`demo listing {id} failed: {tostring(err)}`, 0)
	end
	return created
end

-- `sellerIds` are the six pretend sellers, 101 to 106 (the first six entries are used).
function DemoSeed.seed(
	listings: any,
	index: any,
	now: number,
	sellerIds: { number },
	playerUserId: number?,
	env: Env
): Result
	local Listing = env.Listing
	local result: Result = { ids = {}, claim = nil }
	local nItems = #env.items
	assert(nItems > 0, "DemoSeed needs at least one item id")
	assert(#sellerIds >= #PLAN, "DemoSeed needs six seller ids")

	local function open(
		id: string,
		seller: number,
		itemId: string,
		qty: number,
		kind: string,
		price: number,
		ends: number
	)
		local created = write(listings, Listing, id, {
			id = id,
			seller = seller,
			itemId = itemId,
			qty = qty,
			kind = kind,
			price = if kind == "fixed" then price else nil,
			startBid = if kind == "auction" then price else nil,
			fee = env.fee,
			endsAt = ends,
		}, now, false)
		if created ~= nil then
			table.insert(result.ids, id)
			index:add(created)
		end
	end

	for i, plan in PLAN do
		open(
			`demo-{i}`,
			sellerIds[i],
			env.items[(i - 1) % nItems + 1],
			plan.qty,
			plan.kind,
			plan.price,
			now + plan.hours * HOUR
		)
	end
	-- One auction from seller 104 that ends 90 seconds after the seed.
	open("demo-ending", sellerIds[4], env.items[1], 2, "auction", 30, now + 90)

	if playerUserId ~= nil then
		local id = `demo-sold-{playerUserId}`
		local itemId = env.items[1]
		local created = write(listings, Listing, id, {
			id = id,
			seller = playerUserId,
			itemId = itemId,
			qty = SOLD_QTY,
			kind = "fixed",
			price = SOLD_PRICE,
			startBid = nil,
			fee = env.fee,
			endsAt = now + HOUR,
		}, now, true)
		if created ~= nil then
			table.insert(result.ids, id)
		end
		if created ~= nil then -- a listing that already existed has been paid out once
			result.claim = {
				kind = "listing",
				listingId = id,
				itemId = itemId,
				qty = SOLD_QTY,
				amount = SOLD_PRICE,
				fee = env.fee,
				id = id,
				at = now,
			}
		end
	end
	return result
end

return DemoSeed
