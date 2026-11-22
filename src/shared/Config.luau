--!strict
return table.freeze({
	DataStoreName = "SaleyardsPlayerData_v1", -- change it and every player starts fresh
	SchemaVersion = 1, -- bump when the saved data shape changes, and add a migration step
	AutosaveSeconds = 60, -- how often each session is written
	LeaseSeconds = 180, -- must be well over AutosaveSeconds, or a busy server loses its own lock
	LoadRetries = 5, -- attempts to load a profile before giving up
	RetryBaseSeconds = 1, -- doubles each retry: 1, 2, 4, 8 (five attempts, four waits)
	CloseTimeoutSeconds = 25, -- BindToClose gets about 30 s in total, leave headroom
	ListingStoreName = "SaleyardsListings_v1", -- the DataStore holding every listing, one key per listing
	IndexByPrice = "SaleyardsByPrice_v1", -- the MemoryStore sorted map that orders open listings by price
	IndexByEnding = "SaleyardsByEnding_v1", -- the MemoryStore sorted map that orders open listings by end time
	StartingCoins = 500, -- what a new player's profile starts with
	-- item id -> count handed to a new player, every id must exist in Items
	StartingItems = table.freeze({ hay_bale = 6, fleece = 4, horseshoe = 8 }),
	ListingFee = 5, -- Coins charged up front to list, not refunded
	SaleTax = 0.1, -- share of a sale price kept by the yards, from 0 to 1
	MinIncrement = 5, -- the least a bid must beat the current bid by, in Coins
	MinPrice = 1, -- the lowest starting or buy-now price, in Coins
	MaxPrice = 100000, -- the highest starting or buy-now price, in Coins
	MaxQty = 99, -- the most of one item in a single listing
	ListingHours = table.freeze({ 1, 6, 24 }), -- the durations a seller may pick, in hours
	MaxOpenClaims = 10, -- how many unfinished claims one profile may hold at once
	SettleSeconds = 30, -- how long after a listing ends before it is settled
	NoticeCap = 20, -- how many notices a profile keeps, the oldest are dropped
	BrowsePageSize = 20, -- listings returned per page when browsing
	Limits = table.freeze({
		BurstPerPlayer = 6, -- remote calls a player can make in a burst
		RefillPerSecond = 2, -- calls handed back to each player per second
	}),
	-- id -> item. name is shown to players and colour is {r, g, b} (0 to 255) for the placeholder part.
	Items = table.freeze({
		hay_bale = table.freeze({ name = "Hay Bale", colour = table.freeze({ 220, 190, 90 }) }),
		fleece = table.freeze({ name = "Fleece", colour = table.freeze({ 235, 230, 215 }) }),
		horseshoe = table.freeze({ name = "Horseshoe", colour = table.freeze({ 140, 140, 150 }) }),
		saddle = table.freeze({ name = "Saddle", colour = table.freeze({ 140, 90, 55 }) }),
		milk_can = table.freeze({ name = "Milk Can", colour = table.freeze({ 190, 200, 210 }) }),
		wool_bale = table.freeze({ name = "Wool Bale", colour = table.freeze({ 205, 190, 160 }) }),
	}),
})
