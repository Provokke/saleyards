--!strict
local Conservation = require("../fakes/Conservation")
local Deep = require("../fakes/Deep")
local Listing = require("../../src/server/Listing")

local TAX = 0.1
local NOW = 200

-- Seller 1 listed one wood for 40 and paid a fee of 5; buyer 2 bought it. Tax is floor(40 * 0.1) = 4.
local startCoins = { [1] = 100, [2] = 100 }
local startItems = { [1] = { wood = 3 }, [2] = {} }

local function world(): { [string]: any }
	local listing = Listing.create(nil, {
		id = "L1",
		seller = 1,
		itemId = "wood",
		qty = 1,
		kind = "fixed",
		price = 40,
		fee = 5,
		endsAt = 100,
	}, 0)
	assert(listing)
	local sold = Listing.buy(listing, 2, "buy1", 40, 10)
	assert(sold and sold.state == "sold")
	return {
		L1 = sold,
		["profile/1"] = { coins = 100 - 5 + 40 - 4, items = { wood = 2 }, claims = {} },
		["profile/2"] = { coins = 100 - 40, items = { wood = 1 }, claims = {} },
	}
end

local function expectFail(records: { [string]: any }, needle: string)
	local ok, reason = Conservation.check(records, startCoins, startItems, TAX, NOW)
	assert(not ok, "expected the check to fail")
	assert(reason ~= nil and string.find(reason, needle, 1, true), `reason {reason} lacks {needle}`)
end

return {
	{
		name = "a settled world with one sale of 40 (tax 4, fee 5) passes",
		run = function()
			local ok, reason = Conservation.check(world(), startCoins, startItems, TAX, NOW)
			assert(ok, reason)
			assert(reason == nil)
		end,
	},
	{
		name = "one extra Coin in a profile fails on coins and names the numbers",
		run = function()
			local w = world()
			w["profile/1"].coins += 1
			expectFail(w, "coins: profiles hold 192, expected 191")
		end,
	},
	{
		name = "one missing item fails on items and names the item",
		run = function()
			local w = world()
			w["profile/2"].items = {}
			expectFail(w, "items: wood profiles hold 2, expected 3")
		end,
	},
	{
		name = "one claim left over fails on claims",
		run = function()
			local w = world()
			w["profile/1"].claims = { c1 = { kind = "paySeller" } }
			expectFail(w, "claims: profile/1 still has 1 claim")
		end,
	},
	{
		name = "tax taken from the wrong amount fails on coins",
		run = function()
			local w = world()
			-- the seller was charged tax on 30 instead of 40: 3 rather than 4
			w["profile/1"].coins = 100 - 5 + 40 - 3
			expectFail(w, "coins: profiles hold 192, expected 191")
		end,
	},
	{
		name = "a void listing costs no fee, an unsold one costs its fee and no tax, a won auction pays tax",
		run = function()
			local w = world()
			-- control: the unchanged world passes
			assert(Conservation.check(w, startCoins, startItems, TAX, NOW))
			w["L2"] = { id = "L2", state = "void", voided = { v = true }, settled = { seller = false } }
			assert(Conservation.check(w, startCoins, startItems, TAX, NOW), "a void listing owes nothing")
			local open = Listing.create(nil, {
				id = "L3",
				seller = 1,
				itemId = "wood",
				qty = 1,
				kind = "auction",
				startBid = 10,
				fee = 2,
				endsAt = 150,
			}, 0)
			assert(open)
			w["L3"] = open
			w["profile/1"].coins -= 2
			assert(
				Conservation.check(w, startCoins, startItems, TAX, NOW),
				"an unsold listing owes only its fee"
			)
			local won = Listing.bid(open, 2, "bid1", 25, 1, 20)
			assert(won)
			w["L3"] = won
			-- ended at 150 <= NOW, so 25 is a sale: tax floor(2.5) = 2 comes out of the seller's pay
			w["profile/1"].coins += 25 - 2
			w["profile/2"].coins -= 25
			assert(Conservation.check(w, startCoins, startItems, TAX, NOW), "a won auction pays floor tax")
			local early, reason = Conservation.check(Deep.copy(w), startCoins, startItems, TAX, 100)
			assert(not early and reason, "the same auction before its end is not yet a sale")
		end,
	},
}
