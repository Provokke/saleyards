--!strict
local Config = require("../../src/shared/Config")
local ConfigCheck = require("../../src/shared/ConfigCheck")
local Deep = require("../fakes/Deep")

-- Breaks a deep copy of the shipped config with `change`, and checks the check fails with a
-- reason that names `needle`. The unbroken copy must pass first, so a failure is the change's.
local function flagged(change: (config: any) -> (), needle: string)
	local config = Deep.copy(Config)
	assert(ConfigCheck.check(config), "control: the shipped config is clean")
	change(config)
	local ok, reason = ConfigCheck.check(config)
	assert(ok == false, `expected a failure naming "{needle}"`)
	assert(
		reason ~= nil and string.find(reason, needle, 1, true),
		`expected "{needle}", got: {tostring(reason)}`
	)
end

return {
	{
		name = "the shipped config passes",
		run = function()
			local ok, reason = ConfigCheck.check(Config)
			assert(ok, tostring(reason))
			assert(reason == nil, "no reason on success")
		end,
	},
	{
		name = "a missing or non-number field is flagged",
		run = function()
			flagged(function(c)
				c.SaleTax = nil
			end, "SaleTax")
			flagged(function(c)
				c.StartingCoins = "500"
			end, "StartingCoins")
			flagged(function(c)
				c.SettleSeconds = nil
			end, "SettleSeconds")
			flagged(function(c)
				c.BrowsePageSize = {}
			end, "BrowsePageSize")
			flagged(function(c)
				c.MaxPrice = 0 / 0
			end, "MaxPrice")
		end,
	},
	{
		name = "a missing Limits field returns false rather than throwing",
		run = function()
			flagged(function(c)
				c.Limits.BurstPerPlayer = nil
			end, "BurstPerPlayer")
			flagged(function(c)
				c.Limits = nil
			end, "Limits")
			flagged(function(c)
				c.Items = nil
			end, "Items")
			local ok = ConfigCheck.check(nil)
			assert(ok == false)
		end,
	},
	{
		name = "SaleTax outside 0 to 1 is flagged",
		run = function()
			flagged(function(c)
				c.SaleTax = -0.1
			end, "SaleTax")
			flagged(function(c)
				c.SaleTax = 1.5
			end, "SaleTax")
			local config = Deep.copy(Config)
			config.SaleTax = 0
			assert(ConfigCheck.check(config), "0 is allowed")
			config.SaleTax = 1
			assert(ConfigCheck.check(config), "1 is allowed")
		end,
	},
	{
		name = "whole-number fields below their floor or fractional are flagged",
		run = function()
			for _, field in { "MinIncrement", "MinPrice", "MaxQty", "MaxOpenClaims", "NoticeCap" } do
				flagged(function(c)
					c[field] = 0
				end, field)
				flagged(function(c)
					c[field] = 2.5
				end, field)
			end
			flagged(function(c)
				c.ListingFee = -1
			end, "ListingFee")
			flagged(function(c)
				c.ListingFee = 1.5
			end, "ListingFee")
			flagged(function(c)
				c.StartingCoins = -1
			end, "StartingCoins")
			flagged(function(c)
				c.StartingCoins = 10.5
			end, "StartingCoins")
			local config = Deep.copy(Config)
			config.ListingFee = 0
			config.StartingCoins = 0
			assert(ConfigCheck.check(config), "a free fee and no starting coins are allowed")
		end,
	},
	{
		name = "MaxPrice below MinPrice is flagged",
		run = function()
			flagged(function(c)
				c.MaxPrice = c.MinPrice - 1
			end, "MaxPrice")
		end,
	},
	{
		name = "ListingHours must be non-empty whole numbers of 1 or more",
		run = function()
			flagged(function(c)
				c.ListingHours = {}
			end, "ListingHours")
			flagged(function(c)
				c.ListingHours = { 1, 0 }
			end, "ListingHours")
			flagged(function(c)
				c.ListingHours = { 1, 2.5 }
			end, "ListingHours")
			flagged(function(c)
				c.ListingHours = { 1, "6" }
			end, "ListingHours")
			flagged(function(c)
				c.ListingHours = "24"
			end, "ListingHours")
		end,
	},
	{
		name = "StartingItems must name known items with whole counts",
		run = function()
			flagged(function(c)
				c.StartingItems.unicorn = 1
			end, "StartingItems")
			flagged(function(c)
				c.StartingItems.hay_bale = -1
			end, "StartingItems")
			flagged(function(c)
				c.StartingItems.hay_bale = 1.5
			end, "StartingItems")
			flagged(function(c)
				c.StartingItems = nil
			end, "StartingItems")
			local config = Deep.copy(Config)
			config.StartingItems.hay_bale = 0
			assert(ConfigCheck.check(config), "a zero count is allowed")
		end,
	},
	{
		name = "an item needs a name, a valid colour and a short id",
		run = function()
			flagged(function(c)
				c.Items.hay_bale.name = nil
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.name = ""
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.colour = nil
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.colour = { 1, 2 }
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.colour = { 1, 2, 256 }
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.colour = { 1, -2, 3 }
			end, "hay_bale")
			flagged(function(c)
				c.Items.hay_bale.colour = { 1, 2, "3" }
			end, "hay_bale")
			local long = string.rep("a", 33)
			flagged(function(c)
				c.Items[long] = { name = "Long", colour = { 1, 2, 3 } }
			end, long)
			local config = Deep.copy(Config)
			local ok32 = string.rep("a", 32)
			config.Items[ok32] = { name = "Edge", colour = { 0, 128, 255 } }
			assert(ConfigCheck.check(config), "a 32 character id is allowed")
		end,
	},
	{
		name = "LeaseSeconds must exceed AutosaveSeconds",
		run = function()
			flagged(function(c)
				c.LeaseSeconds = c.AutosaveSeconds
			end, "LeaseSeconds")
			flagged(function(c)
				c.LeaseSeconds = c.AutosaveSeconds - 1
			end, "LeaseSeconds")
		end,
	},
	{
		name = "limits of zero or less are flagged",
		run = function()
			flagged(function(c)
				c.Limits.BurstPerPlayer = 0
			end, "BurstPerPlayer")
			flagged(function(c)
				c.Limits.RefillPerSecond = 0
			end, "RefillPerSecond")
			flagged(function(c)
				c.Limits.RefillPerSecond = -1
			end, "RefillPerSecond")
		end,
	},
	{
		name = "names and the other copied timings are checked",
		run = function()
			for _, field in { "DataStoreName", "ListingStoreName", "IndexByPrice", "IndexByEnding" } do
				flagged(function(c)
					c[field] = ""
				end, field)
			end
			flagged(function(c)
				c.SchemaVersion = 0
			end, "SchemaVersion")
			flagged(function(c)
				c.LoadRetries = 0
			end, "LoadRetries")
			flagged(function(c)
				c.RetryBaseSeconds = 0
			end, "RetryBaseSeconds")
			flagged(function(c)
				c.CloseTimeoutSeconds = 0
			end, "CloseTimeoutSeconds")
			flagged(function(c)
				c.AutosaveSeconds = 0
			end, "AutosaveSeconds")
			flagged(function(c)
				c.SettleSeconds = 0
			end, "SettleSeconds")
			flagged(function(c)
				c.BrowsePageSize = 0
			end, "BrowsePageSize")
		end,
	},
}
