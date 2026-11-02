--!strict
--[[
	TipsController — подсказки новичку по ситуации (баннер сверху по центру).

	Каждая подсказка показывается один раз за сессию, по одной за раз.
	Баннер исчезает сам через SHOW_TIME секунд или по кнопке «✕».
	Настройка ShowTips (вкладка «Настройки») выключает подсказки совсем;
	её сохраняет сервер вместе с остальными данными игрока.

	Подсказки только читают то, что клиент и так видит (данные игрока,
	атрибуты своего участка и кассы). Ничего не отправляют на сервер.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Tiers = require(Shared:WaitForChild("Config"):WaitForChild("Tiers"))
local StateController = require(script.Parent:WaitForChild("StateController"))

local localPlayer = Players.LocalPlayer

local CHECK_INTERVAL = 1 -- секунд между проверками
local SHOW_TIME = 12 -- секунд висит подсказка
local GAP = 3 -- секунд между подсказками
local CLASS_TIP_AFTER = 60 -- секунд игры до подсказки про классы

type Context = {
	plot: Model?,
	data: { [string]: any },
	playedFor: number,
}

type Tip = {
	id: string,
	text: string,
	when: (context: Context) -> boolean,
}

local function myPlot(): Model?
	local plots = workspace:FindFirstChild("Plots")
	if plots == nil then
		return nil
	end
	for _, plot in plots:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == localPlayer.UserId then
			return plot :: Model
		end
	end
	return nil
end

local function registerOf(plot: Model): Instance?
	local restaurant = plot:FindFirstChild("Restaurant")
	if restaurant == nil then
		return nil
	end
	for _, descendant in restaurant:GetDescendants() do
		if CollectionService:HasTag(descendant, "CashRegister") then
			return descendant
		end
	end
	return nil
end

-- Порядок важен: при нескольких подходящих показывается первая.
local TIPS: { Tip } = {
	{
		id = "Welcome",
		text = "Это ваш ресторан. Он зарабатывает сам — деньги копятся в кассе у стойки.",
		when = function(context)
			return context.plot ~= nil
		end,
	},
	{
		id = "Repair",
		text = "Ресторан стоит: что-то сломано или кто-то из персонала погиб. Нажмите «Починить» внизу.",
		when = function(context)
			local plot = context.plot
			return plot ~= nil and plot:GetAttribute("Operational") == false
		end,
	},
	{
		id = "Collect",
		text = "Касса заполнена наполовину. Подойдите к ней и нажмите E, чтобы забрать выручку: полная касса больше не копит, а воры охотятся за ней.",
		when = function(context)
			local plot = context.plot
			local register = if plot then registerOf(plot) else nil
			if register == nil then
				return false
			end
			local cash, capacity = register:GetAttribute("Cash"), register:GetAttribute("Capacity")
			return typeof(cash) == "number" and typeof(capacity) == "number" and capacity > 0 and cash >= capacity / 2
		end,
	},
	{
		id = "Upgrade",
		text = "Денег хватает на улучшение ресторана — нажмите «Улучшить» внизу. Чем выше уровень, тем больше доход и крепче стены.",
		when = function(context)
			local restaurant = context.data.Restaurant
			local nextTier = if restaurant then Tiers[restaurant.Tier + 1] else nil
			return nextTier ~= nil and (context.data.Cash or 0) >= nextTier.UpgradeCost
		end,
	},
	{
		id = "Defense",
		text = "Наймите охрану во вкладке «Охрана»: она защищает кассу от воров.",
		when = function(context)
			local restaurant = context.data.Restaurant
			return restaurant ~= nil and restaurant.Tier >= 2 and next(restaurant.Defense or {}) == nil
		end,
	},
	{
		id = "Class",
		text = "Во вкладке «Класс» выберите роль: разведчик тихо взламывает чужие кассы, подрывник ломает стены, танк принимает огонь на себя.",
		when = function(context)
			return context.playedFor >= CLASS_TIP_AFTER
		end,
	},
}

local TipsController = {}

local banner: Frame
local label: TextLabel
local shown: { [string]: boolean } = {}
local current: string? = nil
local hideAt = 0
local nextAllowedAt = 0
local startedAt = os.clock()

local function enabled(): boolean
	local settings = StateController:get("Settings")
	return settings == nil or settings.ShowTips ~= false
end

local function hide()
	if current then
		current = nil
		nextAllowedAt = os.clock() + GAP
	end
	banner.Visible = false
end

local function show(tip: Tip)
	shown[tip.id] = true
	current = tip.id
	hideAt = os.clock() + SHOW_TIME
	label.Text = tip.text
	banner.Visible = true
end

-- Какая подсказка сейчас на экране (nil — никакой).
function TipsController:getCurrent(): string?
	return current
end

local function check()
	if not enabled() then
		hide()
		return
	end
	local now = os.clock()
	if current then
		if now >= hideAt then
			hide()
		end
		return
	end
	if now < nextAllowedAt or not StateController:isLoaded() then
		return
	end
	local context: Context = {
		plot = myPlot(),
		data = {
			Cash = StateController:get("Cash"),
			Restaurant = StateController:get("Restaurant"),
		},
		playedFor = now - startedAt,
	}
	for _, tip in TIPS do
		if not shown[tip.id] and tip.when(context) then
			show(tip)
			return
		end
	end
end

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "Tips"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	banner = Instance.new("Frame")
	banner.Name = "TipBanner"
	banner.Visible = false
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 12)
	banner.Size = UDim2.new(0, 520, 0, 64)
	banner.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
	banner.BackgroundTransparency = 0.1
	banner.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = banner

	label = Instance.new("TextLabel")
	label.Name = "TipLabel"
	label.Position = UDim2.new(0, 14, 0, 6)
	label.Size = UDim2.new(1, -64, 1, -12)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(240, 240, 240)
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = banner

	local close = Instance.new("TextButton")
	close.Name = "TipClose"
	close.Text = "✕"
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -10, 0.5, 0)
	close.Size = UDim2.new(0, 36, 0, 36)
	close.BackgroundColor3 = Color3.fromRGB(46, 50, 62)
	close.TextColor3 = Color3.fromRGB(240, 240, 240)
	close.Font = Enum.Font.GothamBold
	close.TextSize = 16
	close.Parent = banner
	close.Activated:Connect(hide)
end

function TipsController:Start()
	build()
	startedAt = os.clock()
	StateController.Changed:Connect(function(key: string)
		if key == "Settings" and not enabled() then
			hide()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			check()
		end
	end)
end

return TipsController
