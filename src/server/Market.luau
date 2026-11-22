--!strict
-- Market orders the writes. Every operation follows one rule: stake in the profile and save it,
-- then make the shared write, then settle from the listing, which is the source of truth.
--
-- Write order (P = profile save, L = listing UpdateAsync, I = index add, S = settle):
--   list    P (items, fee and a listing claim taken)  ->  L create  ->  I add on success, else S
--   buy     P (Coins and a buy claim taken)           ->  L buy     ->  S
--   bid     P (Coins and a bid claim taken)           ->  L bid     ->  S
--   cancel  L cancel (nothing is staked)              ->  S
--   settle  per claim: read the listing, then L void if the decision asks for it, then L close
--           if the listing is final only because the clock passed endsAt (a read can be stale and
--           another server's clock can be behind, so the end is written before it is acted on, and
--           the decision is made again from the written value), then apply the outcome in memory
--           (no yield, claim removed in the same change); one P at the end, then L markSettled for
--           listing claims and I remove, both best effort. A listing claim that is still on sale
--           goes back into the index and applies nothing.
-- A failed P stops the operation and undoes the in-memory change. A failed or lost L never rolls
-- back: the claim stays and settle resolves it. Listings are only written by Listing transforms.
-- A per-user lock covers every public call and is released on every path.

export type Claim = {
	kind: "listing" | "buy" | "bid",
	listingId: string,
	itemId: string,
	qty: number,
	amount: number,
	fee: number?,
	id: string,
	at: number,
}

export type Profile = {
	coins: number,
	items: { [string]: number },
	claims: { [string]: Claim },
	notices: { { text: string, at: number } },
}

export type StoreLike = {
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	GetAsync: (self: any, key: string, options: any?) -> any,
}

export type Deps = {
	listings: StoreLike,
	index: { add: (self: any, listing: any) -> (), remove: (self: any, id: string) -> () },
	-- save takes the profile the caller changed: a save for a profile that is no longer the player's
	-- live one (they left and came back) must fail rather than write the new session.
	profiles: { get: (userId: number) -> Profile?, save: (userId: number, profile: Profile) -> boolean },
	now: () -> number,
	guid: () -> string,
	log: (string) -> (),
	config: any,
	Listing: any,
	settler: {
		decide: (claim: any, listing: any, now: number, saleTax: number, userId: number) -> any,
		needsClose: (claim: any, listing: any, now: number, userId: number) -> boolean,
	},
}

export type Market = {
	busy: (self: Market, userId: number) -> boolean,
	list: (
		self: Market,
		userId: number,
		itemId: string,
		qty: number,
		kind: string,
		priceOrStart: number,
		hours: number
	) -> (string?, string?),
	buy: (self: Market, userId: number, listingId: string, price: number) -> (boolean?, string?),
	bid: (self: Market, userId: number, listingId: string, amount: number) -> (boolean?, string?),
	cancel: (self: Market, userId: number, listingId: string) -> (boolean?, string?),
	-- Returns how many claims were applied, then whether the profile is saved: true, false when the
	-- save failed (true when nothing needed saving). While another call holds the user's lock it
	-- returns nil, "busy" instead.
	settle: (self: Market, userId: number) -> (number?, boolean | string | nil),
}

local Market = {}

local function isWhole(n: any): boolean
	return type(n) == "number" and n == math.floor(n) and n >= 1 and n < 2 ^ 53
end

local function countClaims(profile: Profile): number
	local n = 0
	for _ in profile.claims do
		n += 1
	end
	return n
end

function Market.new(deps: Deps): Market
	local listings, index, profiles = deps.listings, deps.index, deps.profiles
	local now, guid, log, config = deps.now, deps.guid, deps.log, deps.config
	local Listing, settler = deps.Listing, deps.settler
	local locks: { [number]: boolean } = {}
	local self = {} :: Market

	local function keyOf(listingId: string): string
		return "listing/" .. listingId
	end

	-- Runs body under the user's lock. Returns nil, "busy" while one is held. The lock is released
	-- on every path, and a raise is re-raised after the release.
	local function locked(userId: number, body: () -> (any, any)): (any, any)
		if locks[userId] then
			return nil, "busy"
		end
		locks[userId] = true
		local ok, a, b = pcall(body)
		locks[userId] = nil
		if not ok then
			error(a, 0)
		end
		return a, b
	end

	-- Saves the profile, treating a raise as a failed save.
	local function saveProfile(userId: number, profile: Profile): boolean
		local ok, saved = pcall(profiles.save, userId, profile)
		return ok and saved == true
	end

	-- One in-memory change with no yield: Coins and items, the claim removed, a notice.
	-- "Hay Bale", or "3 Hay Bales", for a notice.
	local function itemWords(claim: Claim): string
		local item = config.Items[claim.itemId]
		local name = if item then item.name else claim.itemId
		return if claim.qty == 1 then name else `{claim.qty} {name}s`
	end

	local function applyOutcome(profile: Profile, claim: Claim, outcome: any)
		local text = ""
		if outcome.action == "pay" then
			profile.coins += outcome.coins
			text = `Your {itemWords(claim)} sold for {outcome.coins} Coins`
		elseif outcome.action == "return_item" then
			profile.items[claim.itemId] = (profile.items[claim.itemId] or 0) + claim.qty
			if outcome.refundFee then
				profile.coins += claim.fee or 0
			end
			text = `Your {itemWords(claim)} came back to you`
		elseif outcome.action == "give_item" then
			profile.items[claim.itemId] = (profile.items[claim.itemId] or 0) + claim.qty
			text = if claim.kind == "bid"
				then `You won {itemWords(claim)}`
				else `You bought {itemWords(claim)}`
		else -- refund
			profile.coins += outcome.coins
			text = `{outcome.coins} Coins came back to you`
		end
		profile.claims[claim.id] = nil
		if profile.notices == nil then
			profile.notices = {}
		end
		table.insert(profile.notices, { text = text, at = now() })
		while #profile.notices > config.NoticeCap do
			table.remove(profile.notices, 1)
		end
	end

	-- Reads the listing and decides, voiding first when asked, then closing a listing that is final
	-- only by the clock. Returns the outcome, the listing it was decided from and nil, or nil, nil
	-- and the error when a store call failed. Only the store calls are protected: a raise from the
	-- decision itself is a bug and goes up.
	local function decide(claim: Claim, userId: number): (any, any, string?)
		local key = keyOf(claim.listingId)
		local readOk, listing = pcall(function()
			return listings:GetAsync(key)
		end)
		if not readOk then
			return nil, nil, tostring(listing)
		end
		local at = now()
		local outcome = settler.decide(claim, listing, at, config.SaleTax, userId)
		if outcome.action == "void_then_decide" then
			local voidOk, voided = pcall(function()
				return listings:UpdateAsync(key, function(current: any)
					local new = Listing.void(current, claim.listingId, claim.id)
					return new
				end)
			end)
			if not voidOk then
				return nil, nil, tostring(voided)
			end
			listing = voided
			outcome = settler.decide(claim, listing, at, config.SaleTax, userId)
		end
		if settler.needsClose(claim, listing, at, userId) then
			local seen: any = nil
			local refusal: string? = nil
			local closeOk, closed = pcall(function()
				return listings:UpdateAsync(key, function(current: any)
					seen, refusal = current, nil
					local new, reason = Listing.close(current, at)
					refusal = reason
					return new
				end)
			end)
			if not closeOk then
				return nil, nil, tostring(closed)
			end
			if refusal == nil then
				listing = closed
			elseif refusal == "not_open" then
				-- Already final (sold, cancelled, ended): decide from what the transform saw.
				listing = seen
			else
				-- This server's clock is behind the stored end: it is not final here yet.
				return { action = "keep" }, listing, nil
			end
			outcome = settler.decide(claim, listing, at, config.SaleTax, userId)
		end
		return outcome, listing, nil
	end

	-- Settles every claim of one user. The caller holds the lock. Returns how many were applied, the
	-- action each decided claim ended with (a claim with no entry is still held) and whether the
	-- profile is saved (true when nothing needed saving).
	local function settleClaims(userId: number): (number, { [string]: string }, boolean)
		local actions: { [string]: string } = {}
		local profile = profiles.get(userId)
		if profile == nil then
			return 0, actions, true
		end
		local ordered: { Claim } = {}
		for _, claim in profile.claims do
			table.insert(ordered, claim)
		end
		table.sort(ordered, function(a: Claim, b: Claim)
			if a.at ~= b.at then
				return a.at < b.at
			end
			return a.id < b.id
		end)
		local applied = 0
		local settledListings: { string } = {}
		for _, claim in ordered do
			-- A failed store call leaves the claim where it is and moves on.
			local outcome, listing, err = decide(claim, userId)
			if outcome == nil then
				log("settle skipped " .. claim.id .. ": " .. tostring(err))
				continue
			end
			if outcome.action == "keep" then
				actions[claim.id] = "keep"
				-- The seller's open listing, or the auction this bid leads, goes back in the browse
				-- cache from the fresh read, which also carries the current high bid.
				if claim.kind == "listing" or claim.kind == "bid" then
					index:add(listing)
				end
			elseif outcome.action == "void_then_decide" then
				log("settle could not resolve " .. claim.id)
			else
				applyOutcome(profile, claim, outcome)
				actions[claim.id] = outcome.action
				applied += 1
				if claim.kind == "listing" then
					table.insert(settledListings, claim.listingId)
				end
			end
		end
		local saved = true
		if applied > 0 then
			saved = saveProfile(userId, profile)
			if saved then
				for _, listingId in settledListings do
					local removed, removeErr = pcall(function()
						index:remove(listingId)
					end)
					if not removed then
						log("index remove failed: " .. tostring(removeErr))
					end
					local marked, err = pcall(function()
						listings:UpdateAsync(keyOf(listingId), function(current: any)
							local new = Listing.markSettled(current, "seller")
							return new
						end)
					end)
					if not marked then
						log("markSettled failed: " .. tostring(err))
					end
				end
			else
				log("settle save failed for " .. tostring(userId))
			end
		end
		return applied, actions, saved
	end

	function self.busy(_: Market, userId: number): boolean
		return locks[userId] == true
	end

	function self.settle(_: Market, userId: number): (number?, boolean | string | nil)
		return locked(userId, function()
			local applied, _, saved = settleClaims(userId)
			return applied, saved
		end)
	end

	function self.list(
		_: Market,
		userId: number,
		itemId: string,
		qty: number,
		kind: string,
		priceOrStart: number,
		hours: number
	): (string?, string?)
		return locked(userId, function()
			local profile = profiles.get(userId)
			if profile == nil then
				return nil, "no_profile"
			end
			if config.Items[itemId] == nil then
				return nil, "bad_item"
			end
			if not isWhole(qty) or qty > config.MaxQty then
				return nil, "bad_qty"
			end
			local have = profile.items[itemId] or 0
			if have < qty then
				return nil, "not_enough_items"
			end
			local fee: number = config.ListingFee
			if profile.coins < fee then
				return nil, "cant_afford"
			end
			if countClaims(profile) >= config.MaxOpenClaims then
				return nil, "too_many_claims"
			end
			if kind ~= "fixed" and kind ~= "auction" then
				return nil, "bad_kind"
			end
			if
				not isWhole(priceOrStart)
				or priceOrStart < config.MinPrice
				or priceOrStart > config.MaxPrice
			then
				return nil, "bad_price"
			end
			if table.find(config.ListingHours, hours) == nil then
				return nil, "bad_hours"
			end

			local listingId = guid()
			local at = now()
			local claim: Claim = {
				kind = "listing",
				listingId = listingId,
				itemId = itemId,
				qty = qty,
				amount = priceOrStart,
				fee = fee,
				id = listingId,
				at = at,
			}
			-- Write-ahead: take the item and the fee and record the claim, then save.
			profile.items[itemId] = if have - qty > 0 then have - qty else nil
			profile.coins -= fee
			profile.claims[listingId] = claim
			if not saveProfile(userId, profile) then
				profile.items[itemId] = (profile.items[itemId] or 0) + qty
				profile.coins += fee
				profile.claims[listingId] = nil
				return nil, "save_failed"
			end

			local refusal: string? = nil
			local fields = {
				id = listingId,
				seller = userId,
				itemId = itemId,
				qty = qty,
				kind = kind,
				price = if kind == "fixed" then priceOrStart else nil,
				startBid = if kind == "auction" then priceOrStart else nil,
				fee = fee,
				endsAt = at + hours * 3600,
			}
			local ok, created = pcall(function()
				return listings:UpdateAsync(keyOf(listingId), function(current: any)
					refusal = nil
					local new, reason = Listing.create(current, fields, now())
					refusal = reason
					return new
				end)
			end)
			if ok and refusal == nil and created ~= nil then
				index:add(created)
				return listingId, nil
			end
			-- Raised or refused: the claim stays and settlement decides from the listing key.
			local _, actions = settleClaims(userId)
			if actions[listingId] == "keep" then
				return listingId, nil
			end
			if profile.claims[listingId] ~= nil then
				return nil, "pending"
			end
			return nil, "not_listed"
		end)
	end

	-- The shape buy and bid share. Returns (early result, reason, claim id, actions): the claim id
	-- is nil when the call stopped before staking anything.
	local function stake(
		userId: number,
		listingId: string,
		kind: "buy" | "bid",
		amount: number,
		transform: (current: any, claimId: string) -> (any, string?)
	): (boolean?, string?, string?, { [string]: string }?)
		local profile = profiles.get(userId)
		if profile == nil then
			return nil, "no_profile", nil, nil
		end
		if not isWhole(amount) then
			return nil, if kind == "buy" then "bad_price" else "bad_amount", nil, nil
		end
		if profile.coins < amount then
			return nil, "cant_afford", nil, nil
		end
		if countClaims(profile) >= config.MaxOpenClaims then
			return nil, "too_many_claims", nil, nil
		end
		-- Pre-read: the same transform on the current value, to refuse without staking anything.
		local readOk, current = pcall(function()
			return listings:GetAsync(keyOf(listingId))
		end)
		if not readOk then
			return nil, "unavailable", nil, nil
		end
		-- The read yielded: the player may have left and come back, which makes `profile` a dead
		-- session. Staking into it would take Coins from a table nobody saves.
		if profiles.get(userId) ~= profile then
			return nil, "no_profile", nil, nil
		end
		local _, preReason = transform(current, "pre-read")
		if preReason ~= nil then
			return false, preReason, nil, nil
		end

		local claimId = guid()
		local listing: any = current
		profile.coins -= amount
		profile.claims[claimId] = {
			kind = kind,
			listingId = listingId,
			itemId = listing.itemId,
			qty = listing.qty,
			amount = amount,
			id = claimId,
			at = now(),
		}
		if not saveProfile(userId, profile) then
			profile.coins += amount
			profile.claims[claimId] = nil
			return nil, "save_failed", nil, nil
		end

		local refusal: string? = nil
		local wrote, writeErr = pcall(function()
			listings:UpdateAsync(keyOf(listingId), function(cur: any)
				refusal = nil
				local new, reason = transform(cur, claimId)
				refusal = reason
				return new
			end)
		end)
		if not wrote then
			log("stake write failed for " .. claimId .. ": " .. tostring(writeErr))
		end
		local _, actions = settleClaims(userId)
		return nil, refusal, claimId, actions
	end

	function self.buy(_: Market, userId: number, listingId: string, price: number): (boolean?, string?)
		return locked(userId, function()
			local early, reason, claimId, actions = stake(
				userId,
				listingId,
				"buy",
				price,
				function(cur: any, id: string)
					return Listing.buy(cur, userId, id, price, now())
				end
			)
			if claimId == nil or actions == nil then
				return early, reason
			end
			if actions[claimId] == "give_item" then
				return true, nil
			end
			if actions[claimId] == nil then
				return nil, "pending" -- the claim is held and settles later
			end
			return false, reason or "not_bought"
		end)
	end

	function self.bid(_: Market, userId: number, listingId: string, amount: number): (boolean?, string?)
		return locked(userId, function()
			local early, reason, claimId, actions = stake(
				userId,
				listingId,
				"bid",
				amount,
				function(cur: any, id: string)
					return Listing.bid(cur, userId, id, amount, config.MinIncrement, now())
				end
			)
			if claimId == nil or actions == nil then
				return early, reason
			end
			local action = actions[claimId]
			if action == "keep" or action == "give_item" then
				return true, nil
			end
			if action == nil then
				return nil, "pending" -- the claim is held and settles later
			end
			return false, reason or "not_bid"
		end)
	end

	function self.cancel(_: Market, userId: number, listingId: string): (boolean?, string?)
		return locked(userId, function()
			local refusal: string? = nil
			local ok = pcall(function()
				listings:UpdateAsync(keyOf(listingId), function(current: any)
					refusal = nil
					local new, reason = Listing.cancel(current, userId, now())
					refusal = reason
					return new
				end)
			end)
			local _, actions = settleClaims(userId)
			if actions[listingId] == "return_item" or (ok and refusal == nil) then
				local removed, removeErr = pcall(function()
					index:remove(listingId)
				end)
				if not removed then
					log("index remove failed: " .. tostring(removeErr))
				end
				return true, nil
			end
			return false, refusal or "not_cancelled"
		end)
	end

	return self
end

return Market
