--!strict
-- Start-up sanity check for Config. Returns true, or false and a reason that names the field.
-- It never throws, whatever shape it is handed.
local ConfigCheck = {}

local function isNumber(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function isWhole(v: any, min: number): boolean
	return isNumber(v) and v >= min and v % 1 == 0
end

-- The longest item id a client can send. Handlers drop a longer one, so it could never be traded.
local MAX_ID = 32

-- An { r, g, b } colour, each a whole number from 0 to 255.
local function isColour(v: any): boolean
	if type(v) ~= "table" or #v ~= 3 then
		return false
	end
	for i = 1, 3 do
		if not isWhole(v[i], 0) or v[i] > 255 then
			return false
		end
	end
	return true
end

local TOP_NUMBERS = {
	"SchemaVersion",
	"AutosaveSeconds",
	"LeaseSeconds",
	"LoadRetries",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"StartingCoins",
	"ListingFee",
	"SaleTax",
	"MinIncrement",
	"MinPrice",
	"MaxPrice",
	"MaxQty",
	"MaxOpenClaims",
	"SettleSeconds",
	"NoticeCap",
	"BrowsePageSize",
}

local NAMES = { "DataStoreName", "ListingStoreName", "IndexByPrice", "IndexByEnding" }

-- Whole numbers with a floor. The fee and the starting coins may be zero, the rest need one.
local WHOLE_FLOORS: { { any } } = {
	{ "SchemaVersion", 1 },
	{ "LoadRetries", 1 },
	{ "ListingFee", 0 },
	{ "MinIncrement", 1 },
	{ "MinPrice", 1 },
	{ "MaxQty", 1 },
	{ "MaxOpenClaims", 1 },
	{ "StartingCoins", 0 },
	{ "NoticeCap", 1 },
	{ "BrowsePageSize", 1 },
}

local ABOVE_ZERO = {
	"AutosaveSeconds",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"SettleSeconds",
}

function ConfigCheck.check(config: any): (boolean, string?)
	if type(config) ~= "table" then
		return false, "config must be a table"
	end
	for _, field in TOP_NUMBERS do
		if not isNumber(config[field]) then
			return false, `{field} must be a number`
		end
	end
	for _, field in NAMES do
		local v = config[field]
		if type(v) ~= "string" or v == "" then
			return false, `{field} must be a non-empty string`
		end
	end
	for _, entry in WHOLE_FLOORS do
		local field, floor = entry[1], entry[2]
		if not isWhole(config[field], floor) then
			return false, `{field} must be a whole number of {floor} or more`
		end
	end
	for _, field in ABOVE_ZERO do
		if config[field] <= 0 then
			return false, `{field} must be above 0`
		end
	end
	if config.SaleTax < 0 or config.SaleTax > 1 then
		return false, "SaleTax must be from 0 to 1"
	end
	if config.MaxPrice < config.MinPrice then
		return false, "MaxPrice must not be below MinPrice"
	end
	if config.LeaseSeconds <= config.AutosaveSeconds then
		return false, "LeaseSeconds must be above AutosaveSeconds"
	end

	local hours = config.ListingHours
	if type(hours) ~= "table" or next(hours) == nil then
		return false, "ListingHours must be a non-empty list"
	end
	for k, v in hours do
		if type(k) ~= "number" or not isWhole(v, 1) then
			return false, "ListingHours must hold only whole numbers of 1 or more"
		end
	end

	local limits = config.Limits
	if type(limits) ~= "table" then
		return false, "Limits must be a table"
	end
	for _, field in { "BurstPerPlayer", "RefillPerSecond" } do
		if not isNumber(limits[field]) then
			return false, `Limits.{field} must be a number`
		end
		if limits[field] <= 0 then
			return false, `Limits.{field} must be above 0`
		end
	end

	local items = config.Items
	if type(items) ~= "table" then
		return false, "Items must be a table"
	end
	for id, item in items do
		if type(id) ~= "string" or id == "" or #id > MAX_ID then
			return false, `Items id {tostring(id)} must be a string of 1 to {MAX_ID} characters`
		end
		if type(item) ~= "table" then
			return false, `Items.{id} must be a table`
		end
		if type(item.name) ~= "string" or item.name == "" then
			return false, `Items.{id}.name must be a non-empty string`
		end
		if not isColour(item.colour) then
			return false, `Items.{id}.colour must be three whole numbers from 0 to 255`
		end
	end

	local starting = config.StartingItems
	if type(starting) ~= "table" then
		return false, "StartingItems must be a table"
	end
	for id, count in starting do
		if type(id) ~= "string" or items[id] == nil then
			return false, `StartingItems id {tostring(id)} is not in Items`
		end
		if not isWhole(count, 0) then
			return false, `StartingItems.{id} must be a whole number of 0 or more`
		end
	end
	return true, nil
end

return ConfigCheck
