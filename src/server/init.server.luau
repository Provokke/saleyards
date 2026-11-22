--!strict
-- Saleyards server entry. This is where services, remotes, the DataStores and the sorted maps are
-- touched. The rules themselves live in the modules next to it and are covered by the Lune tests.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Saleyards")
local Config = require(Shared:WaitForChild("Config"))
local ConfigCheck = require(Shared:WaitForChild("ConfigCheck"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Validate = require(Shared:WaitForChild("Validate"))

local DemoSeed = require(script.DemoSeed)
local Handlers = require(script.Handlers)
local Index = require(script.Index)
local Lease = require(script.Data.Lease)
local Listing = require(script.Listing)
local Market = require(script.Market)
local MemoryStore = require(script.Data.MemoryStore)
local Migrations = require(script.Data.Migrations)
local Profile = require(script.Data.Profile)
local Sessions = require(script.Sessions)
local Settle = require(script.Settle)
local Steps = require(script.Data.Steps)
local Store = require(script.Data.Store)

local configOk, configProblem = ConfigCheck.check(Config)
if not configOk then
	warn("[Saleyards] config problem: " .. tostring(configProblem))
	warn("[Saleyards] not starting until the config is fixed.")
	return
end

local function log(message: string)
	warn("[Saleyards] " .. message)
end

-- Data stores. Studio uses in-memory tables unless ServerStorage has SaleyardsUseDataStore = true.
local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("SaleyardsUseDataStore") == true
local playerStore: any
local listingStore: any
if useRealStore then
	playerStore = DataStoreService:GetDataStore(Config.DataStoreName)
	listingStore = DataStoreService:GetDataStore(Config.ListingStoreName)
else
	playerStore = MemoryStore.new()
	listingStore = MemoryStore.new()
	print(
		"[Saleyards] Studio: using in-memory stores. Set ServerStorage attribute SaleyardsUseDataStore to use the real ones."
	)
end

-- Every Studio play test gets its own id, so a lease left behind by a crashed or parallel test
-- reads as someone else's (and runs out) rather than as ours.
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local profile = Profile.new({ startingCoins = Config.StartingCoins, startingItems = Config.StartingItems })

local store = Store.new({
	dataStore = playerStore,
	lease = Lease,
	migrations = Migrations,
	clock = os.time,
	wait = task.wait,
	budget = function(_kind: string): number
		if not useRealStore then
			return 100 -- the in-memory store has no request budget
		end
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end,
	jobId = jobId,
	nonce = function(): string
		return HttpService:GenerateGUID(false)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	leaseSeconds = Config.LeaseSeconds,
	retries = Config.LoadRetries,
	retryBase = Config.RetryBaseSeconds,
	schema = Config.SchemaVersion,
	steps = Steps,
	defaultData = profile.defaultData,
	encode = profile.encode,
	decode = profile.decode,
	log = log,
})

-- The browse cache. Always the real MemoryStore: it works in Studio, and Index only logs a failure.
local index = Index.new(
	MemoryStoreService:GetSortedMap(Config.IndexByPrice),
	MemoryStoreService:GetSortedMap(Config.IndexByEnding),
	os.time,
	log,
	Enum.SortDirection.Ascending
)

-- Remotes. Request is client to server (intent only), Sync is server to client, Browse is a
-- request for one page of the open listings.
local request = Instance.new("RemoteEvent")
request.Name = "Request"
request.Parent = Shared
local sync = Instance.new("RemoteEvent")
sync.Name = "Sync"
sync.Parent = Shared
local browse = Instance.new("RemoteFunction")
browse.Name = "Browse"
browse.Parent = Shared

local sessions: any
local handlers: any
local market: any

-- Demo data: Studio only, the in-memory stores only (never pretend sellers in a real data store),
-- and only with the SaleyardsDemoSeed attribute on ServerStorage.
local demoOn = RunService:IsStudio()
	and not useRealStore
	and ServerStorage:GetAttribute("SaleyardsDemoSeed") == true
local demoEnv = {
	Listing = Listing,
	items = { "hay_bale", "fleece", "horseshoe", "saddle", "milk_can", "wool_bale" },
	fee = Config.ListingFee,
}
local demoSellers = { 101, 102, 103, 104, 105, 106 }
local demoDone: { [number]: boolean } = {}

-- The last notice each player was sent, so a Sync carries only what is new. Notices are tables
-- in the profile and the oldest are dropped from the front, so the last one sent is found by
-- identity. If it has been dropped, everything left is new.
local lastNotice: { [number]: any } = {}

local function newNotices(userId: number, notices: { any }): { any }
	local start = 1
	local last = lastNotice[userId]
	if last ~= nil then
		local at = table.find(notices, last)
		if at ~= nil then
			start = at + 1
		end
	end
	local out = {}
	for i = start, #notices do
		table.insert(out, { text = notices[i].text, at = notices[i].at })
	end
	if #notices > 0 then
		lastNotice[userId] = notices[#notices]
	end
	return out
end

-- What one player sees: their Coins, items, open claims (oldest first) and the notices since the
-- last Sync, plus the answer to the call that caused it. Sent on join, after every call and after
-- every settle that applied something.
local function syncPlayer(userId: number, result: any?)
	local player = Players:GetPlayerByUserId(userId)
	local session = sessions:get(userId)
	if player == nil or session == nil then
		return
	end
	local data = session.data
	local items = table.clone(data.items)
	local claims = {}
	for _, claim in data.claims do
		table.insert(claims, {
			id = claim.id,
			kind = claim.kind,
			listingId = claim.listingId,
			itemId = claim.itemId,
			qty = claim.qty,
			amount = claim.amount,
			at = claim.at,
		})
	end
	table.sort(claims, function(a: any, b: any): boolean
		if a.at ~= b.at then
			return a.at < b.at
		end
		return a.id < b.id
	end)
	local payload: { [string]: any } = {
		coins = data.coins,
		items = items,
		claims = claims,
		notices = newNotices(userId, data.notices),
		result = result,
	}
	pcall(function()
		sync:FireClient(player, payload)
	end)
end

-- Settles a player's claims and syncs them if anything was applied. Never throws.
local function settlePlayer(userId: number)
	local ok, applied = pcall(function()
		local count = market:settle(userId)
		return count
	end)
	if not ok then
		log(`settle failed for {userId}: {tostring(applied)}`)
		return
	end
	if applied ~= nil and applied > 0 then
		syncPlayer(userId, nil)
	end
end

-- A session went live: show it, then settle whatever it holds. The settle runs in its own thread,
-- as it yields, and the join is not held up by it.
local function onSessionReady(userId: number, session: any)
	if demoOn and not demoDone[userId] then
		demoDone[userId] = true
		local ok, seeded = pcall(DemoSeed.seed, listingStore, index, os.time(), demoSellers, userId, demoEnv)
		if not ok then
			log("demo seed failed: " .. tostring(seeded))
		elseif seeded.claim ~= nil and session.data.claims[seeded.claim.id] == nil then
			session.data.claims[seeded.claim.id] = seeded.claim
		end
	end
	syncPlayer(userId, nil)
	task.spawn(settlePlayer, userId)
end

sessions = Sessions.new({
	store = store,
	keyFor = function(userId: number): string
		return "Player_" .. userId
	end,
	present = function(player: any): boolean
		return player.Parent ~= nil
	end,
	kick = function(player: any, message: string)
		player:Kick(message)
	end,
	playerOf = function(userId: number): any
		return Players:GetPlayerByUserId(userId)
	end,
	ready = onSessionReady,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
	clock = os.clock,
	closeSeconds = Config.CloseTimeoutSeconds,
	log = log,
	-- A release on leave or shutdown waits for a market call that is still running.
	inUse = function(userId: number): boolean
		return handlers ~= nil and handlers:busy(userId)
	end,
})

market = Market.new({
	listings = listingStore,
	index = index,
	profiles = {
		-- Only a session that would be saved may change anything: a read-only or lost one has no
		-- profile here, so the market refuses it.
		get = function(userId: number): any
			local session = sessions:writableSession(userId)
			return if session ~= nil then session.data else nil
		end,
		-- Saves only the profile the caller changed. If the player has left and come back since,
		-- that table belongs to a dead session, so saving "their" session would write a different
		-- profile than the one the caller staked into.
		save = function(userId: number, staked: any): boolean
			local session = sessions:writableSession(userId)
			if session == nil or session.data ~= staked then
				return false
			end
			return sessions:saveNow(userId)
		end,
	},
	now = os.time,
	guid = function(): string
		return HttpService:GenerateGUID(false)
	end,
	log = log,
	config = Config,
	Listing = Listing,
	settler = Settle.new(Listing),
})

handlers = Handlers.new({
	validate = Validate,
	limiter = RateLimiter.new(Config.Limits.BurstPerPlayer, Config.Limits.RefillPerSecond, os.clock),
	config = Config,
	market = market,
	index = index,
	allowed = function(userId: number): boolean
		return sessions:writableSession(userId) ~= nil
	end,
	sync = syncPlayer,
	log = log,
})

request.OnServerEvent:Connect(function(player: Player, action: any, a: any, b: any, c: any, d: any, e: any)
	local ok, err = pcall(function()
		handlers:handle(player.UserId, action, a, b, c, d, e)
	end)
	if not ok then
		log("request error: " .. tostring(err))
	end
end)

browse.OnServerInvoke = function(player: Player, sort: any, after: any): any
	local ok, page = pcall(function()
		return handlers:browse(player.UserId, sort, after)
	end)
	if not ok then
		log("browse error: " .. tostring(page))
		return nil
	end
	return page
end

-- Sessions
local function onPlayerAdded(player: Player)
	sessions:join(player.UserId, player)
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	handlers.deps.limiter:forget(userId)
	lastNotice[userId] = nil
	demoDone[userId] = nil
	sessions:leave(userId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Autosave. A session that has lost its lease is kicked rather than allowed to carry on unsaved.
task.spawn(function()
	while true do
		task.wait(Config.AutosaveSeconds)
		sessions:saveAll()
	end
end)

-- Settle poll. A listing is settled a while after it ends, so every player holding a claim is
-- settled every SettleSeconds. Settling also puts the player's open listings back into the index.
task.spawn(function()
	while true do
		task.wait(Config.SettleSeconds)
		for _, player in Players:GetPlayers() do
			local userId = player.UserId
			local session = sessions:writableSession(userId)
			if session ~= nil and next(session.data.claims) ~= nil then
				task.spawn(settlePlayer, userId)
			end
		end
	end
end)

-- Releases every session (each after the market call still running for it) and waits for loads and
-- releases still running, within the timeout.
game:BindToClose(function()
	sessions:close()
end)
