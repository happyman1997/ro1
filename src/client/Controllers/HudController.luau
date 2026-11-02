--!strict
--[[
	HudController — основной интерфейс игрока.

	• Сверху слева: деньги, уровень ресторана, состояние («работает» / «стоит»).
	• Снизу: «Улучшить», «Починить» (только когда ресторан стоит), «Охрана»,
	  «Магазин», «Класс».
	• Панели: охрана (наём и увольнение по слотам), магазин оружия, выбор класса.

	Интерфейс только отправляет просьбы серверу (Net.fire) и показывает данные
	из StateController и атрибутов своего участка. Цены и доступность здесь —
	подсказка для игрока; решает и проверяет всё сервер.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Classes = require(Config:WaitForChild("Classes"))
local Defense = require(Config:WaitForChild("Defense"))
local Tiers = require(Config:WaitForChild("Tiers"))
local Weapons = require(Config:WaitForChild("Weapons"))
local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))
local StateController = require(script.Parent:WaitForChild("StateController"))

local localPlayer = Players.LocalPlayer

local COLORS = {
	panel = Color3.fromRGB(24, 26, 32),
	button = Color3.fromRGB(46, 50, 62),
	accent = Color3.fromRGB(255, 190, 60),
	text = Color3.fromRGB(240, 240, 240),
	muted = Color3.fromRGB(160, 165, 175),
	good = Color3.fromRGB(110, 210, 120),
	bad = Color3.fromRGB(235, 90, 80),
}
local DISMISS_REFUND = 0.5 -- как в DefenseService (только для текста кнопки)

local HudController = {}

local gui: ScreenGui
local labels: { [string]: TextLabel } = {}
local buttons: { [string]: TextButton } = {}
local panels: { [string]: Frame } = {}
local panelBuilders: { [string]: (list: Instance) -> () } = {}

--------------------------------------------------------------------------------
-- Построение интерфейса
--------------------------------------------------------------------------------

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className :: any)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function rounded(instance: Instance, radius: number)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, instance)
end

local function formatMoney(value: number): string
	local digits = tostring(math.floor(value))
	local result = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return "$" .. result:gsub("^%s+", "")
end

local function makeButton(name: string, text: string, parent: Instance, onClick: () -> ()): TextButton
	local button = make("TextButton", {
		Name = name,
		Text = text,
		Size = UDim2.new(0, 170, 0, 44),
		BackgroundColor3 = COLORS.button,
		TextColor3 = COLORS.text,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		AutoButtonColor = true,
	}, parent)
	rounded(button, 8)
	button.Activated:Connect(onClick)
	return button
end

local function makePanel(name: string, title: string): Frame
	local panel = make("Frame", {
		Name = name,
		Visible = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 460, 0, 380),
		BackgroundColor3 = COLORS.panel,
		BackgroundTransparency = 0.05,
	}, gui)
	rounded(panel, 12)
	make("TextLabel", {
		Name = "Title",
		Text = title,
		Position = UDim2.new(0, 16, 0, 10),
		Size = UDim2.new(1, -80, 0, 30),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.accent,
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)
	local close = makeButton("CloseButton", "✕", panel, function()
		panel.Visible = false
	end)
	close.Size = UDim2.new(0, 40, 0, 32)
	close.Position = UDim2.new(1, -52, 0, 10)
	local list = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.new(0, 12, 0, 50),
		Size = UDim2.new(1, -24, 1, -62),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	panels[name] = panel
	return panel
end

local function clearList(list: Instance)
	for _, child in list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function makeRow(list: Instance, key: string, text: string, order: number): Frame
	local row = make("Frame", {
		Name = "Row_" .. key,
		Size = UDim2.new(1, -8, 0, 48),
		BackgroundColor3 = COLORS.button,
		BackgroundTransparency = 0.4,
		LayoutOrder = order,
	}, list)
	rounded(row, 8)
	make("TextLabel", {
		Name = "Label",
		Text = text,
		Position = UDim2.new(0, 10, 0, 0),
		Size = UDim2.new(1, -200, 1, 0),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.text,
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	return row
end

local function rowButton(row: Frame, name: string, text: string, index: number, onClick: () -> ()): TextButton
	local button = makeButton(name, text, row, onClick)
	button.Size = UDim2.new(0, 170, 0, 36)
	button.Position = UDim2.new(1, -180, 0, 6 + (index - 1) * 40)
	if index > 1 then
		row.Size = UDim2.new(1, -8, 0, 8 + index * 40)
	end
	return button
end

--------------------------------------------------------------------------------
-- Данные
--------------------------------------------------------------------------------

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

local function currentTier(): number
	local restaurant = StateController:get("Restaurant")
	return if restaurant then restaurant.Tier else 1
end

local function sortedKeys(dictionary: { [string]: any }, by: ((string) -> number)?): { string }
	local keys = {}
	for key in dictionary do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		if by then
			local va, vb = by(a), by(b)
			if va ~= vb then
				return va < vb
			end
		end
		return a < b
	end)
	return keys
end

--------------------------------------------------------------------------------
-- Обновление
--------------------------------------------------------------------------------

local function refreshHeader()
	labels.CashLabel.Text = formatMoney(StateController:get("Cash") or 0)
	local tier = currentTier()
	local info = Tiers[tier]
	labels.TierLabel.Text = if info then `{info.Name} · уровень {tier}` else ""

	local plot = myPlot()
	local operational = if plot then plot:GetAttribute("Operational") ~= false else true
	labels.StatusLabel.Text = if operational
		then "Ресторан работает"
		else "Ресторан стоит — нужен ремонт"
	labels.StatusLabel.TextColor3 = if operational then COLORS.good else COLORS.bad

	local nextInfo = Tiers[tier + 1]
	buttons.UpgradeButton.Text = if nextInfo
		then `Улучшить — {formatMoney(nextInfo.UpgradeCost)}`
		else "Максимальный уровень"
	buttons.RepairButton.Visible = not operational
	if info then
		buttons.RepairButton.Text = `Починить — {formatMoney(info.RepairCost)}`
	end
end

panelBuilders.DefensePanel = function(list: Instance)
	local plot = myPlot()
	local restaurant = if plot then plot:FindFirstChild("Restaurant") else nil
	local hired = (StateController:get("Restaurant") or { Defense = {} }).Defense
	if restaurant == nil then
		makeRow(list, "Empty", "Ресторан ещё не построен", 1)
		return
	end
	local slots = {}
	for _, descendant in restaurant:GetDescendants() do
		if CollectionService:HasTag(descendant, "DefenseSlot") then
			table.insert(slots, descendant)
		end
	end
	table.sort(slots, function(a, b)
		return tostring(a:GetAttribute("SlotId")) < tostring(b:GetAttribute("SlotId"))
	end)
	local tier = currentTier()
	for order, slot in slots do
		local slotId = slot:GetAttribute("SlotId")
		local kind = slot:GetAttribute("SlotKind")
		if typeof(slotId) ~= "string" then
			continue
		end
		local occupantType = hired[slotId]
		local occupant = if occupantType then Defense[occupantType] else nil
		local kindName = if kind == "Turret" then "турель" else "охранник"
		local row = makeRow(
			list,
			slotId,
			`{slotId} ({kindName}): {if occupant then occupant.Name else "свободно"}`,
			order
		)
		if occupant then
			local refund = math.floor(occupant.Cost * DISMISS_REFUND)
			rowButton(row, `Dismiss_{slotId}`, `Уволить (+{formatMoney(refund)})`, 1, function()
				Net.fire("DismissDefender", slotId)
			end)
		else
			local index = 0
			for _, defenderType in
				sortedKeys(Defense, function(key)
					return Defense[key].Cost
				end)
			do
				local info = Defense[defenderType]
				if info.Kind == kind then
					index += 1
					local text = if tier >= info.MinTier
						then `{info.Name} {formatMoney(info.Cost)}`
						else `{info.Name}: с {info.MinTier} ур.`
					rowButton(row, `Hire_{slotId}_{defenderType}`, text, index, function()
						Net.fire("HireDefender", slotId, defenderType)
					end)
				end
			end
		end
	end
end

panelBuilders.ShopPanel = function(list: Instance)
	local owned = (StateController:get("Equipment") or { Weapons = {} }).Weapons
	local order = 0
	for _, weaponId in
		sortedKeys(Weapons, function(key)
			return Weapons[key].Price
		end)
	do
		local info = Weapons[weaponId]
		if info.Price > 0 then
			order += 1
			local row = makeRow(
				list,
				weaponId,
				`{info.Name}: урон {info.Damage}, выстрел раз в {info.FireInterval} с, дальность {info.Range}`,
				order
			)
			local isOwned = owned[weaponId] ~= nil
			rowButton(
				row,
				`Buy_{weaponId}`,
				if isOwned then "Куплено" else `Купить {formatMoney(info.Price)}`,
				1,
				function()
					if not isOwned then
						Net.fire("BuyWeapon", weaponId)
					end
				end
			)
		end
	end
end

panelBuilders.ClassPanel = function(list: Instance)
	local current = StateController:get("Class")
	for order, classId in sortedKeys(Classes) do
		local info = Classes[classId]
		local row = makeRow(list, classId, `{info.Name} — {info.Role}. Здоровье {info.MaxHealth}`, order)
		rowButton(row, `Class_{classId}`, if classId == current then "Выбран" else "Выбрать", 1, function()
			Net.fire("SelectClass", classId)
		end)
	end
end

local function rebuildPanel(name: string)
	local panel: Frame? = panels[name]
	local builder: ((list: Instance) -> ())? = panelBuilders[name]
	if panel == nil or builder == nil or not panel.Visible then
		return
	end
	local list = panel:FindFirstChild("List")
	if list then
		clearList(list)
		builder(list)
	end
end

local function refreshAll()
	refreshHeader()
	for name in panels do
		rebuildPanel(name)
	end
end

local function togglePanel(name: string)
	for panelName, panel in panels do
		panel.Visible = panelName == name and not panel.Visible
	end
	rebuildPanel(name)
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	gui = make("ScreenGui", { Name = "Hud", ResetOnSpawn = false, IgnoreGuiInset = false }, playerGui)

	local header = make("Frame", {
		Name = "Header",
		Position = UDim2.new(0, 12, 0, 12),
		Size = UDim2.new(0, 280, 0, 96),
		BackgroundColor3 = COLORS.panel,
		BackgroundTransparency = 0.15,
	}, gui)
	rounded(header, 10)
	labels.CashLabel = make("TextLabel", {
		Name = "CashLabel",
		Position = UDim2.new(0, 14, 0, 6),
		Size = UDim2.new(1, -28, 0, 36),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.accent,
		Font = Enum.Font.GothamBold,
		TextSize = 30,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)
	labels.TierLabel = make("TextLabel", {
		Name = "TierLabel",
		Position = UDim2.new(0, 14, 0, 44),
		Size = UDim2.new(1, -28, 0, 22),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.text,
		Font = Enum.Font.Gotham,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)
	labels.StatusLabel = make("TextLabel", {
		Name = "StatusLabel",
		Position = UDim2.new(0, 14, 0, 68),
		Size = UDim2.new(1, -28, 0, 20),
		BackgroundTransparency = 1,
		TextColor3 = COLORS.good,
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, header)

	local bar = make("Frame", {
		Name = "ActionBar",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.new(1, -24, 0, 44),
		BackgroundTransparency = 1,
	}, gui)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, bar)
	buttons.UpgradeButton = makeButton("UpgradeButton", "Улучшить", bar, function()
		Net.fire("UpgradeRestaurant")
	end)
	buttons.UpgradeButton.Size = UDim2.new(0, 230, 0, 44)
	buttons.RepairButton = makeButton("RepairButton", "Починить", bar, function()
		Net.fire("RepairRestaurant")
	end)
	buttons.RepairButton.BackgroundColor3 = COLORS.bad
	buttons.RepairButton.Visible = false
	buttons.DefenseTab = makeButton("DefenseTab", "Охрана", bar, function()
		togglePanel("DefensePanel")
	end)
	buttons.ShopTab = makeButton("ShopTab", "Магазин", bar, function()
		togglePanel("ShopPanel")
	end)
	buttons.ClassTab = makeButton("ClassTab", "Класс", bar, function()
		togglePanel("ClassPanel")
	end)
	for order, name in { "UpgradeButton", "RepairButton", "DefenseTab", "ShopTab", "ClassTab" } do
		buttons[name].LayoutOrder = order
	end

	makePanel("DefensePanel", "Охрана ресторана")
	makePanel("ShopPanel", "Магазин оружия")
	makePanel("ClassPanel", "Класс")
end

-- Следим за атрибутами своего участка (владелец, уровень, «работает»).
local function watchPlots()
	local plots = workspace:WaitForChild("Plots")
	local function watch(plot: Instance)
		for _, attribute in { "OwnerUserId", "Operational", "Tier" } do
			plot:GetAttributeChangedSignal(attribute):Connect(refreshAll)
		end
	end
	for _, plot in plots:GetChildren() do
		watch(plot)
	end
	plots.ChildAdded:Connect(watch)
end

function HudController:Start()
	build()
	StateController.Loaded:Connect(refreshAll)
	StateController.Changed:Connect(refreshAll)
	watchPlots()
	refreshAll()
end

return HudController
