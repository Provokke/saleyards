--!strict
-- One simulated server's view of player profiles, kept in the same store as the listings under
-- "profile/<userId>". It holds profiles in memory only for as long as the server lives: a new
-- TestProfiles after a restart reads the store again.
local Deep = require("./Deep")

local TestProfiles = {}
TestProfiles.__index = TestProfiles

export type Profile = {
	coins: number,
	items: { [string]: number },
	claims: { [string]: any },
	notices: { any },
}

type Store = {
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	GetAsync: (self: any, key: string) -> any,
}

export type TestProfiles = typeof(setmetatable(
	{} :: {
		store: Store,
		startCoins: number,
		startItems: { [string]: number },
		profiles: { [number]: Profile },
	},
	TestProfiles
))

function TestProfiles.new(store: Store, startCoins: number, startItems: { [string]: number }?): TestProfiles
	return setmetatable({
		store = store,
		startCoins = startCoins,
		startItems = startItems or {},
		profiles = {},
	}, TestProfiles)
end

function TestProfiles.key(userId: number): string
	return "profile/" .. tostring(userId)
end

-- The in-memory profile, loaded from the store on first use or created with the defaults.
function TestProfiles.get(self: TestProfiles, userId: number): Profile
	local existing = self.profiles[userId]
	if existing then
		return existing
	end
	local stored = self.store:GetAsync(TestProfiles.key(userId))
	local profile: Profile
	if stored ~= nil then
		profile = Deep.copy(stored)
	else
		profile = { coins = self.startCoins, items = Deep.copy(self.startItems), claims = {}, notices = {} }
	end
	self.profiles[userId] = profile
	return profile
end

-- Writes the in-memory profile with UpdateAsync. False when the call raises, including a crash.
-- `undo` runs when the write fails, as the real session runs it inside its lock.
function TestProfiles.save(self: TestProfiles, userId: number, undo: (() -> ())?): boolean
	local profile = self.profiles[userId]
	assert(profile ~= nil, "save of a profile that was never loaded")
	local snapshot = Deep.copy(profile)
	local ok = pcall(function()
		self.store:UpdateAsync(TestProfiles.key(userId), function()
			return Deep.copy(snapshot)
		end)
	end)
	if not ok and undo ~= nil then
		undo()
	end
	return ok
end

return TestProfiles
