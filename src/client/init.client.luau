--!strict
-- Saleyards client entry. Builds the board, the Coins counter and the toasts, and talks to the
-- server. The client never changes a balance itself: it sends what the player tried to do and
-- redraws from the next Sync.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Saleyards")
local Config = require(Shared:WaitForChild("Config"))
local BoardLogic = require(Shared:WaitForChild("BoardLogic"))

local Theme = require(script.Theme)
local Board = require(script.Board)

local localPlayer = Players.LocalPlayer
local request = Shared:WaitForChild("Request") :: RemoteEvent
local sync = Shared:WaitForChild("Sync") :: RemoteEvent
local browse = Shared:WaitForChild("Browse") :: RemoteFunction

local MAX_TOASTS_PER_SYNC = 3

local gui = Instance.new("ScreenGui")
gui.Name = "Saleyards"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = localPlayer:WaitForChild("PlayerGui")

-- Coins, top right. The number counts towards its new value rather than jumping.
local coinPanel = Instance.new("Frame")
coinPanel.Name = "Coins"
coinPanel.AnchorPoint = Vector2.new(1, 0)
coinPanel.Position = UDim2.new(1, -16, 0, 16)
coinPanel.Size = UDim2.fromOffset(200, 40)
coinPanel.Parent = gui
Theme.style(coinPanel, Theme.panel)

local coinLabel = Theme.label(coinPanel, "", 18, Theme.coin)
coinLabel.FontFace = Theme.fontBold
coinLabel.Position = UDim2.fromOffset(14, 0)
coinLabel.Size = UDim2.new(1, -28, 1, 0)

local shownCoins = Config.StartingCoins -- what is on screen
local targetCoins = shownCoins -- what the server last said
coinLabel.Text = BoardLogic.coins(shownCoins)

local function stepCoins()
	if shownCoins == targetCoins then
		return
	end
	-- Move a fraction of the way, and at least 1, so a big change still finishes quickly.
	local gap = targetCoins - shownCoins
	local move = math.max(1, math.floor(math.abs(gap) * 0.2))
	shownCoins = if math.abs(gap) <= move then targetCoins else shownCoins + math.sign(gap) * move
	coinLabel.Text = BoardLogic.coins(shownCoins)
end

-- Toasts, stacked under the Coins counter. Each fades in, waits, and fades out.
local toasts = Instance.new("Frame")
toasts.Name = "Toasts"
toasts.AnchorPoint = Vector2.new(1, 0)
toasts.Position = UDim2.new(1, -16, 0, 68)
toasts.Size = UDim2.fromOffset(300, 0)
toasts.AutomaticSize = Enum.AutomaticSize.Y
toasts.BackgroundTransparency = 1
toasts.Parent = gui
local toastLayout = Instance.new("UIListLayout")
toastLayout.Padding = UDim.new(0, 8)
toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
toastLayout.Parent = toasts

local toastCount = 0
local function toast(text: string, outline: Color3?)
	toastCount += 1
	local card = Instance.new("CanvasGroup")
	card.LayoutOrder = toastCount
	card.Size = UDim2.fromOffset(300, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.GroupTransparency = 1
	card.Parent = toasts
	Theme.style(card, Theme.panel, outline or Theme.stroke)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = card
	local label = Theme.label(card, text, 15)
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.TextWrapped = true
	task.spawn(function()
		TweenService:Create(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
		}):Play()
		task.wait(4.5)
		local out =
			TweenService:Create(card, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				GroupTransparency = 1,
			})
		out:Play()
		out.Completed:Wait()
		card:Destroy()
	end)
end

local board = Board.new({
	theme = Theme,
	logic = BoardLogic,
	config = Config,
	parent = gui,
	userId = localPlayer.UserId,
	now = function(): number
		return workspace:GetServerTimeNow()
	end,
	fetch = function(sort: string, after: any?): any
		local ok, page = pcall(function()
			return browse:InvokeServer(sort, after)
		end)
		return if ok then page else nil
	end,
	onList = function(itemId: string, qty: number, kind: string, price: number, hours: number)
		request:FireServer("list", itemId, qty, kind, price, hours)
	end,
	onBuy = function(listingId: string, price: number)
		request:FireServer("buy", listingId, price)
	end,
	onBid = function(listingId: string, amount: number)
		request:FireServer("bid", listingId, amount)
	end,
	onCancel = function(listingId: string)
		request:FireServer("cancel", listingId)
	end,
})

local openButton = Theme.button(gui, "Market  (M)")
openButton.AnchorPoint = Vector2.new(0, 1)
openButton.Position = UDim2.new(0, 16, 1, -16)
openButton.Size = UDim2.fromOffset(120, 36)
openButton.Activated:Connect(function()
	board:toggle()
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.KeyCode == Enum.KeyCode.M then
		board:toggle()
	end
end)

sync.OnClientEvent:Connect(function(view: any)
	if type(view) ~= "table" or type(view.coins) ~= "number" or type(view.items) ~= "table" then
		return
	end
	if type(view.claims) ~= "table" then
		view.claims = {}
	end
	targetCoins = view.coins
	board:update(view)

	local result = view.result
	if type(result) == "table" and type(result.action) == "string" and result.ok ~= nil then
		local text = BoardLogic.resultText(result.action, result.ok == true, result.reason)
		-- A held result ("pending") is not a failure, so it does not get the red outline.
		local fine = result.ok == true or result.reason == "pending"
		if text ~= nil then
			toast(text, if fine then Theme.good else Theme.bad)
		end
	end
	if type(view.notices) == "table" then
		local first = math.max(1, #view.notices - MAX_TOASTS_PER_SYNC + 1)
		for i = first, #view.notices do
			local notice = view.notices[i]
			if type(notice) == "table" and type(notice.text) == "string" then
				toast(BoardLogic.noticeText(notice.text, Config.Items), Theme.accent)
			end
		end
	end
end)

RunService.Heartbeat:Connect(function()
	stepCoins()
	board:tick()
end)
