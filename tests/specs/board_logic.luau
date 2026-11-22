--!strict
local BoardLogic = require("../../src/shared/BoardLogic")
local Config = require("../../src/shared/Config")

local limits = {
	MinPrice = Config.MinPrice,
	MaxPrice = Config.MaxPrice,
	MaxQty = Config.MaxQty,
	ListingFee = Config.ListingFee,
	ListingHours = Config.ListingHours,
}

local function draft(over: { [string]: any }): any
	local d: { [string]: any } =
		{ itemId = "hay_bale", qty = 2, kind = "fixed", price = 40, hours = 6, owned = 6, coins = 500 }
	for k, v in over do
		d[k] = v
	end
	return d
end

return {
	{
		name = "coins groups thousands",
		run = function()
			assert(BoardLogic.coins(0) == "0 Coins")
			assert(BoardLogic.coins(45) == "45 Coins")
			assert(BoardLogic.coins(999) == "999 Coins")
			assert(BoardLogic.coins(1000) == "1,000 Coins")
			assert(BoardLogic.coins(100000) == "100,000 Coins")
			assert(BoardLogic.coins(1234567) == "1,234,567 Coins")
		end,
	},
	{
		name = "timeLeft formats hours, minutes, seconds and ended",
		run = function()
			assert(BoardLogic.timeLeft(7500) == "2h 05m")
			assert(BoardLogic.timeLeft(3600) == "1h 00m")
			assert(BoardLogic.timeLeft(303) == "5m 03s")
			assert(BoardLogic.timeLeft(59.9) == "59s")
			assert(BoardLogic.timeLeft(0) == "Ended")
			assert(BoardLogic.timeLeft(-5) == "Ended")
		end,
	},
	{
		name = "minNextBid is the start bid, then high plus increment",
		run = function()
			assert(BoardLogic.minNextBid(20, nil, 5) == 20)
			assert(BoardLogic.minNextBid(20, 0, 5) == 20)
			assert(BoardLogic.minNextBid(20, 50, 5) == 55)
			assert(BoardLogic.minNextBid(100, 50, 5) == 100)
		end,
	},
	{
		name = "receiveAfterTax floors the tax like the server",
		run = function()
			assert(BoardLogic.receiveAfterTax(50, 0.1) == 45)
			assert(BoardLogic.receiveAfterTax(45, 0.1) == 41) -- tax 4.5 floors to 4
			assert(BoardLogic.receiveAfterTax(1, 0.1) == 1)
			assert(BoardLogic.receiveAfterTax(100, 0) == 100)
		end,
	},
	{
		name = "canCancel allows fixed and unbid auctions only",
		run = function()
			assert(BoardLogic.canCancel("fixed", nil) == true)
			assert(BoardLogic.canCancel("auction", false) == true)
			assert(BoardLogic.canCancel("auction", nil) == true)
			assert(BoardLogic.canCancel("auction", true) == false)
		end,
	},
	{
		name = "draftProblem accepts a good draft",
		run = function()
			assert(BoardLogic.draftProblem(draft({}), limits) == nil)
			assert(BoardLogic.draftProblem(draft({ kind = "auction" }), limits) == nil)
		end,
	},
	{
		name = "draftProblem refuses each bad field",
		run = function()
			assert(BoardLogic.draftProblem(draft({ owned = 0 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ qty = 0 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ qty = 1.5 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ qty = 7 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ qty = false }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ price = 0 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ price = Config.MaxPrice + 1 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ price = false }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ kind = "swap" }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ hours = 5 }), limits) ~= nil)
			assert(BoardLogic.draftProblem(draft({ coins = Config.ListingFee - 1 }), limits) ~= nil)
		end,
	},
	{
		name = "every reason the server gives has plain words",
		run = function()
			local generic = BoardLogic.reasonText("zzz_unknown")
			for _, reason in
				{
					"pending",
					"busy",
					"cant_afford",
					"not_enough_items",
					"too_low",
					"already_high",
					"own_listing",
					"price_changed",
					"has_bids",
					"not_yours",
					"not_open",
					"ended",
					"not_ended",
					"missing",
					"not_listed",
					"bad_listing",
					"exists",
					"not_fixed",
					"not_auction",
					"voided",
					"too_many_claims",
					"save_failed",
					"unavailable",
					"no_profile",
					"bad_item",
					"bad_qty",
					"bad_price",
					"bad_amount",
					"bad_kind",
					"bad_hours",
				}
			do
				local text = BoardLogic.reasonText(reason)
				assert(text ~= generic, reason .. " has no line of its own")
				assert(not string.find(text, "_"), reason .. " leaks a code")
			end
			assert(BoardLogic.reasonText(nil) == generic)
		end,
	},
	{
		name = "resultText says what happened",
		run = function()
			assert(BoardLogic.resultText("buy", true, nil) == "Bought. It's in your items")
			assert(BoardLogic.resultText("cancel", true, nil) == "Listing cancelled")
			assert(BoardLogic.resultText("bid", false, "too_low") == BoardLogic.reasonText("too_low"))
			assert(BoardLogic.resultText("buy", false, "pending") == BoardLogic.reasonText("pending"))
		end,
	},
	{
		name = "a browse row shows the high bid once an auction has one, and says which price it is",
		run = function()
			local amount, note = BoardLogic.rowPrice("auction", nil, 15, nil)
			assert(amount == 15 and note == "start bid", `{amount} {note}`)
			amount, note = BoardLogic.rowPrice("auction", nil, 15, 22)
			assert(amount == 22 and note == "high bid", `{amount} {note}`)
			amount, note = BoardLogic.rowPrice("fixed", 40, nil, nil)
			assert(amount == 40 and note == "buy now", `{amount} {note}`)
		end,
	},
}
