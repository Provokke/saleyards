--!strict
-- The browse cache: open listings in two sorted maps, one ordered by price and one by end time.
-- It is only a cache. Every call is wrapped in pcall, a failure is logged and never raised, and
-- losing an entry loses no item or Coin, because the listing key is the source of truth.

export type SortedMapLike = {
	SetAsync: (self: any, key: string, value: any, expiration: number, sortKey: number) -> any,
	RemoveAsync: (self: any, key: string) -> any,
	GetRangeAsync: (self: any, direction: any, count: number, lower: any?, upper: any?) -> any,
}

export type Entry = {
	id: string,
	itemId: string,
	qty: number,
	kind: string,
	price: number?,
	startBid: number?,
	endsAt: number,
	seller: number,
}

export type After = { key: string, sortKey: number }

export type Page = { entries: { Entry }, nextAfter: After? }

export type Index = {
	add: (self: Index, l: any) -> (),
	remove: (self: Index, id: string) -> (),
	page: (self: Index, sort: "price" | "ending", after: After?, count: number) -> Page,
}

local Index = {}

-- `ascending` is the direction passed to GetRangeAsync. The server script passes
-- Enum.SortDirection.Ascending, because this module touches no Roblox service.
function Index.new(
	byPrice: SortedMapLike,
	byEnding: SortedMapLike,
	now: () -> number,
	log: (string) -> (),
	ascending: any?
): Index
	local direction: any = if ascending ~= nil then ascending else "Ascending"
	local self = {} :: Index

	function self.add(_: Index, l: any)
		local ok, err = pcall(function()
			local expiration = math.max(1, l.endsAt - now())
			local entry: Entry = {
				id = l.id,
				itemId = l.itemId,
				qty = l.qty,
				kind = l.kind,
				price = l.price,
				startBid = l.startBid,
				endsAt = l.endsAt,
				seller = l.seller,
			}
			byPrice:SetAsync(l.id, entry, expiration, l.price or l.startBid)
			byEnding:SetAsync(l.id, entry, expiration, l.endsAt)
		end)
		if not ok then
			log("index add failed: " .. tostring(err))
		end
	end

	function self.remove(_: Index, id: string)
		for _, map in { byPrice, byEnding } do
			local ok, err = pcall(function()
				map:RemoveAsync(id)
			end)
			if not ok then
				log("index remove failed: " .. tostring(err))
			end
		end
	end

	function self.page(_: Index, sort: "price" | "ending", after: After?, count: number): Page
		local map = if sort == "price" then byPrice else byEnding
		local ok, items = pcall(function()
			return map:GetRangeAsync(direction, count, after)
		end)
		if not ok then
			log("index page failed: " .. tostring(items))
			return { entries = {}, nextAfter = nil }
		end
		local entries: { Entry } = {}
		local last: After? = nil
		for _, item in items :: { any } do
			table.insert(entries, item.value)
			last = { key = item.key, sortKey = item.sortKey }
		end
		return { entries = entries, nextAfter = if #entries >= count then last else nil }
	end

	return self
end

return Index
