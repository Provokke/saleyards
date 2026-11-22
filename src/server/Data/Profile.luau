--!strict
-- The shape of one player's saved data, and how the session form is turned into the stored form
-- and back.
--
--   coins    number                       the player's wallet
--   items    { [itemId]: count }          what they hold and have not put up for sale
--   claims   { [claimId]: Claim }         unfinished listings, buys and bids, settled by Market
--   notices  { { text, at } }             what happened while they were away, oldest first
--
-- Coins, items and claims live in one record, so every save writes them together. A new
-- profile (schema 1) is made from the starting coins and starting items, and the claim that
-- creates the record writes them, so they are never granted twice. encode and decode copy every
-- field, so a field added to defaultData is saved and loaded without being listed here.
local Profile = {}

type Data = { [string]: any }

export type Deps = {
	startingCoins: number, -- what a new player starts with
	startingItems: { [string]: number }, -- item id -> count handed to a new player
}

export type Profile = {
	defaultData: () -> Data,
	encode: (data: Data) -> Data,
	decode: (saved: Data) -> Data,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

function Profile.new(deps: Deps): Profile
	local function defaultData(): Data
		return {
			coins = deps.startingCoins,
			items = deepCopy(deps.startingItems),
			claims = {},
			notices = {},
		}
	end

	-- Session form to stored form. Runs inside UpdateAsync transforms, so it must not yield.
	local function encode(data: Data): Data
		return deepCopy(data)
	end

	-- Stored form to session form. Data that isn't a table, or that has no coin balance, is
	-- refused, so the load fails and the record is left alone instead of being opened as an
	-- empty profile (which would hand out the starting coins again). A missing items, claims or
	-- notices table is made empty.
	local function decode(saved: Data): Data
		if type(saved) ~= "table" then
			error("saved data is not a table")
		end
		if type(saved.coins) ~= "number" then
			error("saved data has no coins")
		end
		local out = deepCopy(saved)
		for _, field in { "items", "claims", "notices" } do
			if type(out[field]) ~= "table" then
				out[field] = {}
			end
		end
		return out
	end

	return { defaultData = defaultData, encode = encode, decode = decode }
end

return Profile
