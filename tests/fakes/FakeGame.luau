--!strict
-- Runs the real server entry script (src/server/init.server.luau) under Lune, over a small
-- stand-in for the parts of Roblox it touches: the services it asks for, Players, remotes,
-- MemoryStore sorted maps, instances and task. The data store is a FakeDataStore over `records`
-- (player profiles and listings share it, under different keys), and task.spawn and task.wait run
-- on a FakeScheduler, so a test can move the clock and act while something is still in flight.
--
-- Only what the entry script uses is modelled. A call to anything else fails, so a new service
-- or member used by the script shows up here as an error rather than passing quietly.
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local FakeClock = require("./FakeClock")
local FakeDataStore = require("./FakeDataStore")
local FakeScheduler = require("./FakeScheduler")
local FakeSortedMap = require("./FakeSortedMap")
local Faults = require("./Faults")

local SHARED: { [string]: any } = {
	Config = require("../../src/shared/Config"),
	ConfigCheck = require("../../src/shared/ConfigCheck"),
	RateLimiter = require("../../src/shared/RateLimiter"),
	Validate = require("../../src/shared/Validate"),
}

local DATA: { [string]: any } = {
	Lease = require("../../src/server/Data/Lease"),
	MemoryStore = require("../../src/server/Data/MemoryStore"),
	Migrations = require("../../src/server/Data/Migrations"),
	Profile = require("../../src/server/Data/Profile"),
	Steps = require("../../src/server/Data/Steps"),
	Store = require("../../src/server/Data/Store"),
}

local SERVER: { [string]: any } = {
	DemoSeed = require("../../src/server/DemoSeed"),
	Handlers = require("../../src/server/Handlers"),
	Index = require("../../src/server/Index"),
	Listing = require("../../src/server/Listing"),
	Market = require("../../src/server/Market"),
	Sessions = require("../../src/server/Sessions"),
	Settle = require("../../src/server/Settle"),
}

-- Read once, when this module is first required. fs.readFile yields to Lune's scheduler, which a
-- test running in the runner's own thread must not do.
local SOURCE = fs.readFile("src/server/init.server.luau")

local FakeGame = {}

export type Options = {
	config: any?, -- replaces Config
	failRequire: string?, -- the name of a module whose require throws
	blockShared: boolean?, -- ReplicatedStorage:WaitForChild never returns
	start: number?, -- the clock's starting time
	records: any?, -- an existing store to start over, as a restarted server would
	studio: boolean?, -- RunService:IsStudio() answers this (default false)
	attributes: { [string]: any }?, -- ServerStorage attributes
}

local function signal(world: any): any
	local s: any = { fns = {} }
	function s.Connect(self: any, fn: (...any) -> ())
		table.insert(self.fns, fn)
		return {
			Disconnect = function()
				local i = table.find(self.fns, fn)
				if i then
					table.remove(self.fns, i)
				end
			end,
		}
	end
	-- Each handler runs in its own thread, as Roblox does, and an error in one is logged rather
	-- than raised in whoever fired the signal.
	function s.fire(self: any, ...: any)
		for _, fn in table.clone(self.fns) do
			world:spawnLogged(fn, ...)
		end
	end
	return s
end

local function strict(name: string, members: { [string]: any }): any
	return setmetatable(members, {
		__index = function(_, key)
			error(`FakeGame: {name}.{tostring(key)} is not modelled`, 2)
		end,
	})
end

-- A stand-in module reference: what `script.Build` or `Shared:WaitForChild("Config")` gives the
-- entry script, and what its `require` turns back into the module.
local function moduleRef(name: string, value: any): any
	return { __moduleName = name, __module = value }
end

-- A remote that records what was done to it. Parent is a plain field.
local function newInstance(world: any, className: string): any
	local instance: any = { ClassName = className, Name = className, Parent = nil, attributes = {} }
	function instance.SetAttribute(self: any, name: string, value: any)
		self.attributes[name] = value
	end
	function instance.GetAttribute(self: any, name: string): any
		return self.attributes[name]
	end
	function instance.Destroy(self: any)
		self.destroyed = true
	end
	if className == "RemoteEvent" then
		instance.OnServerEvent = signal(world)
		function instance.FireClient(_, player: any, payload: any)
			if world.fireThrows then
				error("FireClient failed")
			end
			table.insert(world.synced, { userId = player.UserId, payload = payload })
		end
	end
	if className == "RemoteFunction" then
		instance.OnServerInvoke = nil
	end
	table.insert(world.instances, instance)
	return instance
end

function FakeGame.new(options: Options?): any
	local opts: Options = options or {}
	local world: any = {
		records = opts.records or {},
		players = {},
		warnings = {},
		prints = {},
		synced = {},
		instances = {},
		fireThrows = false,
		guids = 0,
	}
	world.clock = FakeClock.new(opts.start or 1000)
	world.sched = FakeScheduler.new(world.clock)
	world.ds = FakeDataStore.new(world.records)
	world.maps = {} -- sorted maps by name
	local dsHandle: any = world.ds:handle(Faults.new())
	world.errors = {} -- errors thrown in spawned threads and signal handlers, which Roblox only logs

	-- Runs fn(...) in a new thread on the scheduler, logging an error instead of raising it.
	function world.spawnLogged(self: any, fn: (...any) -> (), ...: any)
		local args = table.pack(...)
		self.sched:spawn(function()
			local ok, err = pcall(fn, table.unpack(args, 1, args.n))
			if not ok then
				table.insert(self.errors, tostring(err))
			end
		end)
	end

	local Players: any
	Players = strict("Players", {
		PlayerAdded = signal(world),
		PlayerRemoving = signal(world),
		GetPlayers = function()
			local list = {}
			for _, player in world.players do
				table.insert(list, player)
			end
			return list
		end,
		GetPlayerByUserId = function(_, userId: number)
			return world.players[userId]
		end,
	})

	local config = opts.config or SHARED.Config
	local sharedFolder = strict("Saleyards", {
		WaitForChild = function(_, name: string)
			local value = if name == "Config" then config else SHARED[name]
			assert(value ~= nil, `FakeGame: no shared module {name}`)
			return moduleRef(name, value)
		end,
	})

	local services: { [string]: any } = {
		DataStoreService = strict("DataStoreService", {
			GetDataStore = function()
				return dsHandle
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		}),
		HttpService = strict("HttpService", {
			GenerateGUID = function()
				world.guids += 1
				return `guid-{world.guids}`
			end,
		}),
		MemoryStoreService = strict("MemoryStoreService", {
			GetSortedMap = function(_, name: string)
				local map = world.maps[name]
				if map == nil then
					map = FakeSortedMap.new(world.clock)
					world.maps[name] = map
				end
				return map:handle(Faults.new())
			end,
		}),
		Players = Players,
		ReplicatedStorage = strict("ReplicatedStorage", {
			WaitForChild = function(_, name: string)
				assert(name == "Saleyards", name)
				if opts.blockShared then
					world.sched:wait(math.huge)
				end
				return sharedFolder
			end,
		}),
		RunService = strict("RunService", {
			IsStudio = function()
				return opts.studio == true
			end,
		}),
		ServerStorage = strict("ServerStorage", {
			GetAttribute = function(_, name: string)
				return if opts.attributes ~= nil then opts.attributes[name] else nil
			end,
		}),
	}

	local function folder(prefix: string, modules: { [string]: any }): any
		local out = {}
		for name, value in modules do
			out[name] = moduleRef(prefix .. name, value)
		end
		return out
	end

	local script: any = { Data = folder("Data.", DATA) }
	for name, value in SERVER do
		script[name] = moduleRef(name, value)
	end

	local env: any = {
		game = strict("game", {
			JobId = "JOB",
			GetService = function(_, name: string)
				local service = services[name]
				assert(service ~= nil, `FakeGame: service {name} is not modelled`)
				return service
			end,
			BindToClose = function(_, fn: () -> ())
				world.onClose = fn
			end,
		}),
		script = script,
		require = function(ref: any): any
			assert(type(ref) == "table" and ref.__moduleName ~= nil, "FakeGame: require of a non-module")
			if opts.failRequire == ref.__moduleName then
				error(`{ref.__moduleName} failed to load`)
			end
			return ref.__module
		end,
		Instance = {
			new = function(className: string): any
				return newInstance(world, className)
			end,
		},
		Enum = {
			DataStoreRequestType = { UpdateAsync = "UpdateAsync" },
			SortDirection = { Ascending = "Ascending", Descending = "Descending" },
		},
		task = {
			spawn = function(fn: any, ...: any)
				if type(fn) == "thread" then
					world.sched:spawn(fn)
					return
				end
				world:spawnLogged(fn, ...)
			end,
			wait = function(seconds: number?): number
				world.sched:wait(seconds or 0)
				return seconds or 0
			end,
		},
		os = {
			time = function(): number
				return math.floor(world.clock:now())
			end,
			clock = function(): number
				return world.clock:now()
			end,
		},
		warn = function(...: any)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(world.warnings, table.concat(parts, " "))
		end,
		print = function(...: any)
			table.insert(world.prints, table.concat({ ... }, " "))
		end,
	}

	-- Starts the script in its own thread, as Roblox does. `started` is true once it reaches the
	-- end, and `startError` holds anything it threw.
	function world.start(self: any)
		local chunk = luau.load(SOURCE, { debugName = "init.server", environment = env })
		self.sched:spawn(function()
			local ok, err = pcall(chunk)
			self.started = ok
			self.startError = if ok then nil else tostring(err)
		end)
		return self
	end

	function world.join(self: any, userId: number): any
		local player: any = { UserId = userId, Name = `player{userId}`, Parent = Players, attributes = {} }
		function player.Kick(p: any, message: string)
			p.kicked = message
		end
		self.players[userId] = player
		Players.PlayerAdded:fire(player)
		return player
	end

	-- PlayerRemoving fires while the player is still in Players; then they are gone.
	function world.leave(self: any, userId: number)
		local player = self.players[userId]
		Players.PlayerRemoving:fire(player)
		self.players[userId] = nil
		player.Parent = nil
	end

	function world.remote(self: any, name: string): any
		for _, instance in self.instances do
			if instance.Name == name then
				return instance
			end
		end
		return nil
	end

	-- A client firing the Request remote.
	function world.request(self: any, userId: number, ...: any)
		local remote = self:remote("Request")
		assert(remote ~= nil, "no Request remote")
		remote.OnServerEvent:fire(self.players[userId], ...)
	end

	-- A client calling the Browse remote function. Runs on the caller's thread.
	function world.browse(self: any, userId: number, ...: any): any
		for _, instance in self.instances do
			if instance.Name == "Browse" and instance.ClassName == "RemoteFunction" then
				return instance.OnServerInvoke(self.players[userId], ...)
			end
		end
		error("no Browse remote")
	end

	-- The latest Sync sent to a player.
	function world.lastSync(self: any, userId: number): any
		for i = #self.synced, 1, -1 do
			if self.synced[i].userId == userId then
				return self.synced[i].payload
			end
		end
		return nil
	end

	return world
end

return FakeGame
