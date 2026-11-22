--!strict
-- The saved shape of a player's profile, and what a brand new or older record opens as.
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local Migrations = require("../../src/server/Data/Migrations")
local Profile = require("../../src/server/Data/Profile")
local Steps = require("../../src/server/Data/Steps")
local StoreServer = require("../fakes/StoreServer")

local function make(): any
	return Profile.new({ startingCoins = Config.StartingCoins, startingItems = Config.StartingItems })
end

return {
	{
		name = "a new profile holds the starting coins and items, and empty claims and notices",
		run = function()
			local data = make().defaultData()
			assert(data.coins == 500, tostring(data.coins))
			assert(Deep.equal(data.items, { hay_bale = 6, fleece = 4, horseshoe = 8 }))
			assert(next(data.claims) == nil and #data.notices == 0)
		end,
	},
	{
		name = "each new profile gets its own copy of the starting items",
		run = function()
			local p = make()
			local a = p.defaultData()
			a.items.hay_bale = 0
			assert(p.defaultData().items.hay_bale == 6, "the next profile is not touched")
			assert(Config.StartingItems.hay_bale == 6, "nor is the config")
		end,
	},
	{
		name = "encode and decode copy every field, including ones the shape does not list",
		run = function()
			local p = make()
			local data = p.defaultData()
			data.extra = { nested = { 1, 2 } }
			data.claims.c1 =
				{ kind = "buy", listingId = "L", itemId = "saddle", qty = 1, amount = 9, id = "c1", at = 5 }
			local stored = p.encode(data)
			assert(Deep.equal(stored, data) and stored ~= data and stored.claims ~= data.claims)
			local opened = p.decode(stored)
			assert(Deep.equal(opened, data) and opened.extra ~= stored.extra)
		end,
	},
	{
		name = "decode refuses data with no coins, and fills missing tables",
		run = function()
			local p = make()
			assert(not pcall(p.decode, { items = {} }), "no coins")
			assert(not pcall(p.decode, { coins = "5" }), "coins of the wrong type")
			assert(not pcall(p.decode, nil :: any), "not a table")
			local opened = p.decode({ coins = 7 })
			assert(opened.coins == 7 and next(opened.items) == nil)
			assert(next(opened.claims) == nil and #opened.notices == 0)
		end,
	},
	{
		name = "migration 1: a first load creates the record at schema 1 from the starting values",
		run = function()
			local records: any = {}
			local clock = FakeClock.new(0)
			local p = make()
			local store = StoreServer.new(records, clock, "JOB", {
				defaultData = p.defaultData,
				encode = p.encode,
				decode = p.decode,
			})
			local session, outcome = store:load("Player_1")
			assert(session ~= nil and outcome == "new", tostring(outcome))
			assert(session.data.coins == 500 and session.data.items.fleece == 4)
			assert(records.Player_1.schema == Config.SchemaVersion and Config.SchemaVersion == 1)
			assert(records.Player_1.data.items.horseshoe == 8, "the creating claim wrote them")
			session.data.coins = 40
			assert(session:release() == true)
			-- control: the second load opens what was saved and grants nothing again
			local again, second = store:load("Player_1")
			assert(again ~= nil and second == "taken", tostring(second))
			assert(again.data.coins == 40 and again.data.items.hay_bale == 6)
		end,
	},
	{
		name = "migration: a current record passes through unchanged and a newer one is read-only",
		run = function()
			local record = {
				schema = 1,
				savedAt = 0,
				data = { coins = 3, items = { saddle = 1 }, claims = {}, notices = {} },
			}
			local data, readOnly = Migrations.run(record, Steps, Config.SchemaVersion)
			assert(Deep.equal(data, record.data) and readOnly == false)
			local newer = { schema = 2, savedAt = 0, data = { coins = 3, mystery = true } }
			local kept, newerRead = Migrations.run(newer, Steps, Config.SchemaVersion)
			assert(newerRead == true and kept.mystery == true)
		end,
	},
}
