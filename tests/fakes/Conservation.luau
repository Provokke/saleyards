--!strict
-- The settled-world check: after every call has finished and every claim has been applied, no
-- Coin and no item has been made or lost. Records are the shared store's table: keys that start
-- with "profile/" are profiles and every other key is a listing.
local Listing = require("../../src/server/Listing")

local Conservation = {}

local PROFILE_PREFIX = "profile/"

function Conservation.check(
	records: { [string]: any },
	startCoins: { [number]: number },
	startItems: { [number]: { [string]: number } },
	saleTax: number,
	now: number
): (boolean, string?)
	local profiles: { [string]: any } = {}
	local listings: { [string]: any } = {}
	for key, record in records do
		if string.sub(key, 1, #PROFILE_PREFIX) == PROFILE_PREFIX then
			profiles[key] = record
		else
			listings[key] = record
		end
	end

	-- No claims left over.
	local keys = {}
	for key in profiles do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local left = 0
		for _ in profiles[key].claims or {} do
			left += 1
		end
		if left > 0 then
			return false, `claims: {key} still has {left} claim(s)`
		end
	end

	-- Coins.
	local profileCoins, start, fees, tax = 0, 0, 0, 0
	for _, profile in profiles do
		profileCoins += profile.coins
	end
	for _, coins in startCoins do
		start += coins
	end
	for _, listing in listings do
		if listing.state ~= "void" then
			fees += listing.fee
			local sale = Listing.saleAmount(listing, now)
			if sale ~= nil then
				tax += math.floor(sale * saleTax)
			end
		end
	end
	local expected = start - fees - tax
	if profileCoins ~= expected then
		return false,
			`coins: profiles hold {profileCoins}, expected {expected} (start {start} - fees {fees} - sale tax {tax})`
	end

	-- Items, per item id.
	local held: { [string]: number } = {}
	local began: { [string]: number } = {}
	for _, profile in profiles do
		for itemId, count in profile.items or {} do
			held[itemId] = (held[itemId] or 0) + count
		end
	end
	for _, items in startItems do
		for itemId, count in items do
			began[itemId] = (began[itemId] or 0) + count
		end
	end
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for itemId in held do
		seen[itemId] = true
		table.insert(ids, itemId)
	end
	for itemId in began do
		if not seen[itemId] then
			table.insert(ids, itemId)
		end
	end
	table.sort(ids)
	for _, itemId in ids do
		local have, want = held[itemId] or 0, began[itemId] or 0
		if have ~= want then
			return false, `items: {itemId} profiles hold {have}, expected {want}`
		end
	end
	return true, nil
end

return Conservation
