--!strict
-- The market board: Browse, Sell and Mine. It draws what the server last sent and reports what the
-- player did; it never changes Coins or items itself. Anything it works out (the fee, what a seller
-- would receive, time left) is shown as information, and the server has the final say on all of it.
local Board = {}
Board.__index = Board

type Entry = {
	id: string,
	itemId: string,
	qty: number,
	kind: string,
	price: number?,
	startBid: number?,
	high: number?,
	endsAt: number,
	seller: number,
}

type Page = { entries: { Entry }, nextAfter: { key: string, sortKey: number }? }

type Claim = { id: string, kind: string, listingId: string, itemId: string, qty: number, amount: number }

type View = { coins: number, items: { [string]: number }, claims: { Claim }, result: any? }

type Clock = { label: TextLabel, endsAt: number }

export type Deps = {
	theme: any,
	logic: any, -- BoardLogic
	config: any,
	parent: Instance,
	userId: number,
	now: () -> number, -- server time, in seconds
	fetch: (sort: string, after: any?) -> Page?, -- yields, nil when the call was dropped
	onList: (itemId: string, qty: number, kind: string, price: number, hours: number) -> (),
	onBuy: (listingId: string, price: number) -> (),
	onBid: (listingId: string, amount: number) -> (),
	onCancel: (listingId: string) -> (),
}

export type Board = typeof(setmetatable(
	{} :: {
		deps: Deps,
		root: Frame,
		tabs: { [string]: TextButton },
		panes: { [string]: Frame },
		tab: string,
		view: View?,
		-- Browse
		sort: string,
		cursors: { any }, -- the `after` cursor for each page, the first is nil
		pageNumber: number,
		page: Page?,
		loading: boolean,
		failed: boolean,
		again: boolean,
		browseList: ScrollingFrame,
		browseNote: TextLabel,
		sortButtons: { [string]: TextButton },
		prev: TextButton,
		next: TextButton,
		pageLabel: TextLabel,
		clocks: { Clock },
		-- what this client has learned about listings, to prefill bids and place Cancel
		kindOf: { [string]: string },
		endsOf: { [string]: number },
		bidHint: { [string]: number },
		lastBid: string?,
		lastBidAmount: number,
		lastDraft: { kind: string, hours: number }?,
		-- Sell
		sellList: ScrollingFrame,
		selected: string?,
		kind: string,
		hours: number,
		qtyBox: TextBox,
		priceBox: TextBox,
		priceLabel: TextLabel,
		kindButtons: { [string]: TextButton },
		hourButtons: { [number]: TextButton },
		feeLine: TextLabel,
		receiveLine: TextLabel,
		problemLine: TextLabel,
		listButton: TextButton,
		-- Mine
		mineList: ScrollingFrame,
	},
	Board
))

local TABS = { "Browse", "Sell", "Mine" }
local ROW_HEIGHT = 58

local function digitsOnly(box: TextBox)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local clean = string.gsub(box.Text, "%D", "")
		if clean ~= box.Text then
			box.Text = clean
		end
	end)
end

local function bold(label: TextLabel, theme: any): TextLabel
	label.FontFace = theme.fontBold
	return label
end

local function scroller(parent: Instance, position: UDim2, size: UDim2): ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = position
	list.Size = size
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = Color3.fromRGB(64, 69, 82)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 8) -- room for the scroll bar
	pad.Parent = list
	return list
end

local function clearRows(list: Instance)
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function itemOf(self: Board, id: string): { name: string, colour: { number }? }
	local item = self.deps.config.Items[id]
	if item ~= nil then
		return item
	end
	return { name = (string.gsub(id, "_", " ")), colour = nil }
end

-- One listing or claim row: a colour chip for the item, a title and a muted line under it.
local function baseRow(self: Board, list: Instance, order: number, itemId: string, qty: number, sub: string)
	local theme = self.deps.theme
	local item = itemOf(self, itemId)
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Parent = list
	theme.style(row, theme.cell)

	local chip = Instance.new("Frame")
	chip.Position = UDim2.fromOffset(12, 9)
	chip.Size = UDim2.fromOffset(40, 40)
	chip.Parent = row
	theme.style(chip, theme.colour(item.colour), theme.stroke)

	local title = bold(theme.label(row, if qty > 1 then `{item.name}  x{qty}` else item.name, 16), theme)
	title.Position = UDim2.fromOffset(64, 9)
	title.Size = UDim2.fromOffset(170, 20)
	local line = theme.label(row, sub, 13, theme.muted)
	line.Position = UDim2.fromOffset(64, 31)
	line.Size = UDim2.fromOffset(190, 18)
	return row
end

local function timeLabel(self: Board, row: Instance, endsAt: number): TextLabel
	local label = self.deps.theme.label(row, "", 14, self.deps.theme.muted)
	label.Position = UDim2.fromOffset(372, 0)
	label.Size = UDim2.new(0, 80, 1, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	table.insert(self.clocks, { label = label, endsAt = endsAt })
	label.Text = self.deps.logic.timeLeft(endsAt - self.deps.now())
	return label
end

local function selectTab(self: Board, name: string)
	self.tab = name
	for tabName, pane in self.panes do
		pane.Visible = tabName == name
	end
	for tabName, button in self.tabs do
		button.BackgroundColor3 = if tabName == name then self.deps.theme.accent else self.deps.theme.cell
	end
	if name == "Browse" and self.page == nil then
		self:loadPage()
	end
end

-- ---------------------------------------------------------------------------------------------
-- Browse

local function drawBrowse(self: Board)
	local theme, logic, config = self.deps.theme, self.deps.logic, self.deps.config
	clearRows(self.browseList)
	self.clocks = {}
	for name, button in self.sortButtons do
		button.BackgroundColor3 = if name == self.sort then theme.accent else theme.cell
	end
	local page = self.page
	local entries = if page ~= nil then page.entries else {}
	self.browseNote.Visible = #entries == 0
	if self.loading and page == nil then
		self.browseNote.Text = "Loading the yards..."
	elseif self.failed then
		self.browseNote.Text = "Couldn't reach the market. Try Refresh in a moment."
	else
		self.browseNote.Text = "Nothing is for sale right now."
	end
	for order, entry in entries do
		local mine = entry.seller == self.deps.userId
		local ended = entry.endsAt <= self.deps.now()
		local sub = if entry.kind == "auction" then "Auction" else "Fixed price"
		if mine then
			sub ..= ", yours"
		end
		local row = baseRow(self, self.browseList, order, entry.itemId, entry.qty, sub)
		local amount = if entry.kind == "auction" then entry.high or entry.startBid or 0 else entry.price or 0
		local price = bold(theme.label(row, logic.coins(amount), 15, theme.coin), theme)
		price.Position = UDim2.fromOffset(238, 9)
		price.Size = UDim2.fromOffset(130, 20)
		local priceNote =
			theme.label(row, if entry.kind == "auction" then "start bid" else "buy now", 12, theme.muted)
		priceNote.Position = UDim2.fromOffset(238, 31)
		priceNote.Size = UDim2.fromOffset(130, 18)
		timeLabel(self, row, entry.endsAt)

		local canAct = not mine and not ended
		if entry.kind == "fixed" then
			local buy = theme.button(row, "Buy", theme.accent)
			buy.AnchorPoint = Vector2.new(1, 0.5)
			buy.Position = UDim2.new(1, -12, 0.5, 0)
			buy.Size = UDim2.fromOffset(110, 32)
			theme.setEnabled(buy, canAct, theme.accent)
			buy.Activated:Connect(function()
				if canAct then
					self.deps.onBuy(entry.id, entry.price or 0)
				end
			end)
		else
			local bid = theme.button(row, "Bid", theme.accent)
			bid.AnchorPoint = Vector2.new(1, 0.5)
			bid.Position = UDim2.new(1, -12, 0.5, 0)
			bid.Size = UDim2.fromOffset(52, 32)
			theme.setEnabled(bid, canAct, theme.accent)
			local box = theme.input(
				row,
				tostring(
					logic.minNextBid(
						entry.startBid or 0,
						math.max(entry.high or 0, self.bidHint[entry.id] or 0),
						config.MinIncrement
					)
				),
				"Bid"
			)
			box.AnchorPoint = Vector2.new(1, 0.5)
			box.Position = UDim2.new(1, -70, 0.5, 0)
			box.Size = UDim2.fromOffset(72, 32)
			digitsOnly(box)
			bid.Activated:Connect(function()
				local value = tonumber(box.Text)
				if canAct and value ~= nil and value >= 1 then
					self.lastBid = entry.id
					self.lastBidAmount = value
					self.deps.onBid(entry.id, value)
				end
			end)
		end
		self.kindOf[entry.id] = entry.kind
		self.endsOf[entry.id] = entry.endsAt
	end
	self.pageLabel.Text = `Page {self.pageNumber}`
	local hasPrev = self.pageNumber > 1
	local hasNext = page ~= nil and page.nextAfter ~= nil
	theme.setEnabled(self.prev, hasPrev)
	theme.setEnabled(self.next, hasNext)
end

function Board.loadPage(self: Board)
	if self.loading then
		self.again = true
		return
	end
	self.loading = true
	self.failed = false
	drawBrowse(self)
	task.spawn(function()
		local after = self.cursors[self.pageNumber]
		if after == false then
			after = nil -- the first page has no cursor
		end
		local page = self.deps.fetch(self.sort, after)
		self.loading = false
		if page == nil or type(page.entries) ~= "table" then
			self.failed = true
		else
			self.page = page
		end
		drawBrowse(self)
		if self.again then
			self.again = false
			self:loadPage()
		end
	end)
end

local function buildBrowse(self: Board, pane: Frame)
	local theme = self.deps.theme
	local sortLabel = theme.label(pane, "Sort by", 14, theme.muted)
	sortLabel.Position = UDim2.fromOffset(0, 6)
	sortLabel.Size = UDim2.fromOffset(60, 20)
	local x = 64
	for _, option in
		{ { id = "price", text = "Price", width = 76 }, { id = "ending", text = "Ending soon", width = 110 } }
	do
		local button = theme.button(pane, option.text)
		button.Position = UDim2.fromOffset(x, 0)
		button.Size = UDim2.fromOffset(option.width, 32)
		x += option.width + 8
		self.sortButtons[option.id] = button
		button.Activated:Connect(function()
			if self.sort ~= option.id then
				self.sort = option.id
				self.cursors = { false }
				self.pageNumber = 1
				self:loadPage()
			end
		end)
	end
	local refresh = theme.button(pane, "Refresh")
	refresh.AnchorPoint = Vector2.new(1, 0)
	refresh.Position = UDim2.new(1, 0, 0, 0)
	refresh.Size = UDim2.fromOffset(90, 32)
	refresh.Activated:Connect(function()
		self:loadPage()
	end)

	self.browseList = scroller(pane, UDim2.fromOffset(0, 42), UDim2.new(1, 0, 1, -88))
	self.browseNote = theme.label(pane, "", 15, theme.muted)
	self.browseNote.Position = UDim2.fromOffset(0, 60)
	self.browseNote.Size = UDim2.new(1, 0, 0, 24)
	self.browseNote.TextXAlignment = Enum.TextXAlignment.Center

	self.prev = theme.button(pane, "Previous")
	self.prev.AnchorPoint = Vector2.new(0, 1)
	self.prev.Position = UDim2.new(0, 0, 1, 0)
	self.prev.Size = UDim2.fromOffset(96, 32)
	self.next = theme.button(pane, "Next")
	self.next.AnchorPoint = Vector2.new(1, 1)
	self.next.Position = UDim2.new(1, 0, 1, 0)
	self.next.Size = UDim2.fromOffset(96, 32)
	self.pageLabel = theme.label(pane, "Page 1", 14, theme.muted)
	self.pageLabel.AnchorPoint = Vector2.new(0.5, 1)
	self.pageLabel.Position = UDim2.new(0.5, 0, 1, -6)
	self.pageLabel.Size = UDim2.fromOffset(120, 20)
	self.pageLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.prev.Activated:Connect(function()
		if self.pageNumber > 1 then
			self.pageNumber -= 1
			self:loadPage()
		end
	end)
	self.next.Activated:Connect(function()
		local page = self.page
		if page ~= nil and page.nextAfter ~= nil then
			self.pageNumber += 1
			self.cursors[self.pageNumber] = page.nextAfter
			self:loadPage()
		end
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Sell

local function currentDraft(self: Board): any
	local view = self.view
	local owned = 0
	if view ~= nil and self.selected ~= nil then
		owned = view.items[self.selected] or 0
	end
	return {
		itemId = self.selected,
		qty = tonumber(self.qtyBox.Text),
		kind = self.kind,
		price = tonumber(self.priceBox.Text),
		hours = self.hours,
		owned = owned,
		coins = if view ~= nil then view.coins else 0,
	}
end

local function refreshSell(self: Board)
	local theme, logic, config = self.deps.theme, self.deps.logic, self.deps.config
	for name, button in self.kindButtons do
		button.BackgroundColor3 = if name == self.kind then theme.accent else theme.cell
	end
	for hours, button in self.hourButtons do
		button.BackgroundColor3 = if hours == self.hours then theme.accent else theme.cell
	end
	self.priceLabel.Text = if self.kind == "auction" then "Start bid" else "Price (whole lot)"
	local draft = currentDraft(self)
	local problem = logic.draftProblem(draft, config)
	self.feeLine.Text = `Listing fee  {logic.coins(config.ListingFee)}, not refunded`
	local percent = math.floor(config.SaleTax * 100 + 0.5)
	if draft.price ~= nil and draft.price >= 1 then
		local suffix = if self.kind == "auction" then " if it sells at the start bid" else ""
		self.receiveLine.Text =
			`You'd receive  {logic.coins(logic.receiveAfterTax(draft.price, config.SaleTax))}{suffix}`
	else
		self.receiveLine.Text = `You'd receive  the price less {percent}% tax`
	end
	self.problemLine.Text = problem or ""
	self.problemLine.Visible = problem ~= nil
	theme.setEnabled(self.listButton, problem == nil, theme.accent)
	if problem == nil then
		self.listButton.BackgroundColor3 = theme.accent
	end
end

local function drawSellList(self: Board)
	local theme = self.deps.theme
	clearRows(self.sellList)
	local view = self.view
	if view == nil then
		return
	end
	local ids: { string } = {}
	for id, count in view.items do
		if count > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	if self.selected ~= nil and (view.items[self.selected] or 0) <= 0 then
		self.selected = nil
	end
	if self.selected == nil then
		self.selected = ids[1]
	end
	if #ids == 0 then
		local empty = theme.label(self.sellList, "You have nothing to sell.", 14, theme.muted)
		empty.Size = UDim2.new(1, 0, 0, 24)
	end
	for order, id in ids do
		local item = itemOf(self, id)
		local chosen = id == self.selected
		local row = Instance.new("TextButton")
		row.AutoButtonColor = false
		row.Text = ""
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, 46)
		row.Parent = self.sellList
		theme.style(
			row,
			if chosen then theme.cell else theme.panel,
			if chosen then theme.accent else theme.stroke
		)
		local chip = Instance.new("Frame")
		chip.Position = UDim2.fromOffset(10, 8)
		chip.Size = UDim2.fromOffset(30, 30)
		chip.Parent = row
		theme.style(chip, theme.colour(item.colour), theme.stroke)
		local name = bold(theme.label(row, item.name, 15), theme)
		name.Position = UDim2.fromOffset(50, 0)
		name.Size = UDim2.new(1, -110, 1, 0)
		local count = theme.label(row, `x{view.items[id]}`, 15, theme.muted)
		count.AnchorPoint = Vector2.new(1, 0)
		count.Position = UDim2.new(1, -10, 0, 0)
		count.Size = UDim2.new(0, 50, 1, 0)
		count.TextXAlignment = Enum.TextXAlignment.Right
		row.Activated:Connect(function()
			self.selected = id
			drawSellList(self)
			refreshSell(self)
		end)
	end
end

local function buildSell(self: Board, pane: Frame)
	local theme, config = self.deps.theme, self.deps.config
	local heading = bold(theme.label(pane, "Your items", 14, theme.muted), theme)
	heading.Size = UDim2.fromOffset(240, 20)
	self.sellList = scroller(pane, UDim2.fromOffset(0, 26), UDim2.new(0, 248, 1, -26))

	local form = Instance.new("Frame")
	form.BackgroundTransparency = 1
	form.Position = UDim2.fromOffset(266, 0)
	form.Size = UDim2.new(1, -266, 1, 0)
	form.Parent = pane
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = form

	local order = 0
	local function field(text: string): (Frame, TextLabel)
		order += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, 32)
		row.Parent = form
		local label = theme.label(row, text, 14, theme.muted)
		label.Size = UDim2.new(0, 120, 1, 0)
		return row, label
	end

	local qtyRow = field("Quantity")
	self.qtyBox = theme.input(qtyRow, "1", "Qty")
	self.qtyBox.Position = UDim2.fromOffset(124, 0)
	self.qtyBox.Size = UDim2.fromOffset(90, 32)
	digitsOnly(self.qtyBox)

	local kindRow = field("Sale type")
	local x = 124
	for _, option in
		{
			{ id = "fixed", text = "Fixed price", width = 100 },
			{ id = "auction", text = "Auction", width = 90 },
		}
	do
		local button = theme.button(kindRow, option.text)
		button.Position = UDim2.fromOffset(x, 0)
		button.Size = UDim2.fromOffset(option.width, 32)
		x += option.width + 8
		self.kindButtons[option.id] = button
		button.Activated:Connect(function()
			self.kind = option.id
			refreshSell(self)
		end)
	end

	local priceRow, priceLabel = field("Price (whole lot)")
	self.priceLabel = priceLabel
	self.priceBox = theme.input(priceRow, "", "Coins")
	self.priceBox.Position = UDim2.fromOffset(124, 0)
	self.priceBox.Size = UDim2.fromOffset(120, 32)
	digitsOnly(self.priceBox)

	local hoursRow = field("Duration")
	x = 124
	for _, hours in config.ListingHours do
		local button = theme.button(hoursRow, `{hours}h`)
		button.Position = UDim2.fromOffset(x, 0)
		button.Size = UDim2.fromOffset(56, 32)
		x += 64
		self.hourButtons[hours] = button
		button.Activated:Connect(function()
			self.hours = hours
			refreshSell(self)
		end)
	end

	order += 1
	local summary = Instance.new("Frame")
	summary.LayoutOrder = order
	summary.Size = UDim2.new(1, 0, 0, 84)
	summary.Parent = form
	theme.style(summary, theme.cell)
	self.feeLine = theme.label(summary, "", 14, theme.muted)
	self.feeLine.Position = UDim2.fromOffset(12, 10)
	self.feeLine.Size = UDim2.new(1, -24, 0, 20)
	self.receiveLine = bold(theme.label(summary, "", 15, theme.coin), theme)
	self.receiveLine.Position = UDim2.fromOffset(12, 32)
	self.receiveLine.Size = UDim2.new(1, -24, 0, 20)
	self.problemLine = theme.label(summary, "", 13, theme.bad)
	self.problemLine.Position = UDim2.fromOffset(12, 56)
	self.problemLine.Size = UDim2.new(1, -24, 0, 20)

	order += 1
	self.listButton = theme.button(form, "List for sale", theme.accent)
	self.listButton.LayoutOrder = order
	self.listButton.Size = UDim2.new(1, 0, 0, 38)
	self.listButton.Activated:Connect(function()
		local draft = currentDraft(self)
		if self.deps.logic.draftProblem(draft, config) ~= nil then
			return
		end
		self.lastDraft = { kind = draft.kind, hours = draft.hours }
		self.deps.onList(draft.itemId, draft.qty, draft.kind, draft.price, draft.hours)
	end)

	self.qtyBox:GetPropertyChangedSignal("Text"):Connect(function()
		refreshSell(self)
	end)
	self.priceBox:GetPropertyChangedSignal("Text"):Connect(function()
		refreshSell(self)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Mine

local function drawMine(self: Board)
	local theme, logic = self.deps.theme, self.deps.logic
	clearRows(self.mineList)
	local view = self.view
	local claims = if view ~= nil then view.claims else {}
	local empty = #claims == 0
	if empty then
		local note = theme.label(self.mineList, "You have nothing listed and no bids in.", 15, theme.muted)
		note.Size = UDim2.new(1, 0, 0, 24)
		note.TextXAlignment = Enum.TextXAlignment.Center
	end
	for order, claim in claims do
		local kind = self.kindOf[claim.listingId]
		local sub: string
		local head: string
		if claim.kind == "listing" then
			head = "Your listing"
			sub = if kind == "auction"
				then `Auction from {logic.coins(claim.amount)}`
				elseif kind == "fixed" then `Fixed at {logic.coins(claim.amount)}`
				else `Listed at {logic.coins(claim.amount)}`
		elseif claim.kind == "bid" then
			head = "Your bid"
			sub = `{logic.coins(claim.amount)} held until it ends`
		else
			head = "Your purchase"
			sub = `{logic.coins(claim.amount)} paid, finishing up`
		end
		local row = baseRow(self, self.mineList, order, claim.itemId, claim.qty, sub)
		local tag = theme.label(row, head, 14, theme.muted)
		tag.Position = UDim2.fromOffset(238, 0)
		tag.Size = UDim2.new(0, 130, 1, 0)
		local endsAt = self.endsOf[claim.listingId]
		if endsAt ~= nil then
			timeLabel(self, row, endsAt)
		end
		if claim.kind == "listing" and logic.canCancel(kind, nil) then
			local cancel = theme.button(row, "Cancel")
			cancel.AnchorPoint = Vector2.new(1, 0.5)
			cancel.Position = UDim2.new(1, -12, 0.5, 0)
			cancel.Size = UDim2.fromOffset(90, 32)
			cancel.Activated:Connect(function()
				self.deps.onCancel(claim.listingId)
			end)
		end
	end
end

-- ---------------------------------------------------------------------------------------------

function Board.new(deps: Deps): Board
	local theme = deps.theme
	local root = Instance.new("Frame")
	root.Name = "Board"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(660, 480)
	root.Visible = false
	root.Parent = deps.parent
	theme.style(root, theme.panel)

	local title = bold(theme.label(root, "Saleyards", 20), theme)
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.fromOffset(180, 26)
	local close = theme.button(root, "X")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -14, 0, 12)
	close.Size = UDim2.fromOffset(30, 26)

	local tabRow = Instance.new("Frame")
	tabRow.BackgroundTransparency = 1
	tabRow.Position = UDim2.fromOffset(16, 50)
	tabRow.Size = UDim2.new(1, -32, 0, 32)
	tabRow.Parent = root
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.Parent = tabRow

	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(16, 96)
	body.Size = UDim2.new(1, -32, 1, -112)
	body.Parent = root

	local self = setmetatable(
		{
			deps = deps,
			root = root,
			tabs = {},
			panes = {},
			tab = "Browse",
			view = nil,
			sort = "price",
			cursors = { false },
			pageNumber = 1,
			page = nil,
			loading = false,
			failed = false,
			again = false,
			sortButtons = {},
			clocks = {},
			kindOf = {},
			endsOf = {},
			bidHint = {},
			lastBid = nil,
			lastBidAmount = 0,
			lastDraft = nil,
			selected = nil,
			kind = "fixed",
			hours = deps.config.ListingHours[2] or deps.config.ListingHours[1],
			kindButtons = {},
			hourButtons = {},
		} :: any,
		Board
	) :: Board

	for _, name in TABS do
		local button = theme.button(tabRow, name)
		button.Size = UDim2.fromOffset(110, 32)
		button.Activated:Connect(function()
			selectTab(self, name)
		end)
		self.tabs[name] = button
		local pane = Instance.new("Frame")
		pane.Name = name
		pane.BackgroundTransparency = 1
		pane.Size = UDim2.fromScale(1, 1)
		pane.Visible = false
		pane.Parent = body
		self.panes[name] = pane
	end
	buildBrowse(self, self.panes.Browse)
	buildSell(self, self.panes.Sell)
	self.mineList = scroller(self.panes.Mine, UDim2.new(), UDim2.fromScale(1, 1))
	close.Activated:Connect(function()
		self:setVisible(false)
	end)
	selectTab(self, "Browse")
	refreshSell(self)
	return self
end

function Board.setVisible(self: Board, visible: boolean)
	self.root.Visible = visible
	if visible and self.tab == "Browse" then
		self:loadPage()
	end
end

function Board.toggle(self: Board)
	self:setVisible(not self.root.Visible)
end

-- A Sync arrived. Redraws what depends on it, never the Browse rows (that would wipe a bid being
-- typed) and not the Sell fields.
function Board.update(self: Board, view: View)
	self.view = view
	drawSellList(self)
	refreshSell(self)
	drawMine(self)
	local result = view.result
	if type(result) == "table" then
		if
			result.action == "list"
			and result.ok
			and type(result.id) == "string"
			and self.lastDraft ~= nil
		then
			self.kindOf[result.id] = self.lastDraft.kind
			self.endsOf[result.id] = self.deps.now() + self.lastDraft.hours * 3600
			drawMine(self)
		elseif result.action == "bid" and result.reason == "too_low" and self.lastBid ~= nil then
			-- Someone holds a bid we could not see: raise the prefill so the next try is closer.
			self.bidHint[self.lastBid] = self.lastBidAmount
		end
		if result.action ~= nil and self.root.Visible then
			self:loadPage()
		end
	end
end

-- Every frame: moves the time-left labels.
function Board.tick(self: Board)
	if not self.root.Visible then
		return
	end
	local now = self.deps.now()
	for _, clock in self.clocks do
		local text = self.deps.logic.timeLeft(clock.endsAt - now)
		if clock.label.Text ~= text then
			clock.label.Text = text
		end
	end
end

return Board
