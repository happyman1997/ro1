--!strict
--[[
	DefenseService — наём охраны в слоты ресторана.

	• В модели каждого уровня есть слоты: невидимые детали с тегом "DefenseSlot"
	  и атрибутами SlotId ("Door1", "Ceiling1", ...) и SlotKind ("Guard"/"Turret").
	  SlotId одинаковые на всех уровнях, поэтому нанятая охрана переезжает
	  на новый уровень сама.
	• Наём (HireDefender): копия шаблона ServerStorage.Defenders.<тип> ставится
	  в точку слота и попадает в папку Defense участка. Дальше ей управляет
	  GuardAIService. Нанятые записываются в PlayerData.Restaurant.Defense.
	• Увольнение (DismissDefender) возвращает половину цены.
	• Павший защитник возвращается через RESPAWN_DELAY секунд, если ресторан
	  не под атакой (агентство присылает замену), и сразу — при ремонте.

	ЗАЩИТА:
	• Владелец, деньги, уровень ресторана, тип слота, занятость слота, бой —
	  всё проверяет сервер. Нанять охрану посреди штурма нельзя: это было бы
	  мгновенное подкрепление.
	• Цена и характеристики берутся из Config/Defense на сервере.
	• Проверка и списание без yield между ними.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Defense = require(ReplicatedStorage.Shared.Config.Defense)
local Guard = require(ReplicatedStorage.Shared.Guard)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local SLOT_TAG = "DefenseSlot"
local TEMPLATES_FOLDER = "Defenders"
local RESPAWN_DELAY = 45 -- секунд до замены павшего защитника
local RESPAWN_CHECK_INTERVAL = 1
local DISMISS_REFUND = 0.5

type Plot = PlotService.Plot
type Spawned = { model: Model, defenderType: string, deadSince: number? }

local DefenseService = {}

local templates: Instance? = nil
local spawned: { [Plot]: { [string]: Spawned } } = {}

--------------------------------------------------------------------------------
-- Слоты и защитники
--------------------------------------------------------------------------------

local function findSlot(plot: Plot, slotId: string): BasePart?
	local restaurant = plot.restaurant
	if restaurant == nil then
		return nil
	end
	for _, descendant in restaurant:GetDescendants() do
		if
			descendant:IsA("BasePart")
			and CollectionService:HasTag(descendant, SLOT_TAG)
			and descendant:GetAttribute("SlotId") == slotId
		then
			return descendant :: BasePart
		end
	end
	return nil
end

local function isAlive(model: Model): boolean
	if model.Parent == nil then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid.Health > 0
	end
	local health = model:GetAttribute("Health")
	return typeof(health) ~= "number" or health > 0
end

local function removeSpawned(plot: Plot, slotId: string)
	local list = spawned[plot]
	local entry = if list then list[slotId] else nil
	if entry then
		list[slotId] = nil
		entry.model:Destroy()
	end
end

local function spawnDefender(plot: Plot, slotId: string, defenderType: string): boolean
	local info = Defense[defenderType]
	local slot = findSlot(plot, slotId)
	local template = if templates then templates:FindFirstChild(defenderType) else nil
	if info == nil or slot == nil or template == nil or not template:IsA("Model") then
		if template == nil then
			warn(`[DefenseService] Нет шаблона ServerStorage.{TEMPLATES_FOLDER}.{defenderType}`)
		end
		return false
	end
	removeSpawned(plot, slotId)

	local model = (template :: Model):Clone()
	model.Name = `{defenderType}_{slotId}`
	model:SetAttribute("SlotId", slotId)
	model:PivotTo(slot.CFrame)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Модель без суставов: без этого Humanoid может «погибнуть» сам по себе.
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		humanoid.MaxHealth = info.MaxHealth
		humanoid.Health = info.MaxHealth
	else
		model:SetAttribute("Health", info.MaxHealth)
	end
	model.Parent = plot.defenseFolder

	local list = spawned[plot]
	if list == nil then
		list = {}
		spawned[plot] = list
	end
	list[slotId] = { model = model, defenderType = defenderType, deadSince = nil }
	return true
end

-- Поставить всех нанятых защитников заново (новая модель ресторана).
local function spawnAll(plot: Plot)
	local owner = plot.owner
	local data = if owner then DataService:get(owner) else nil
	local list = spawned[plot]
	if list then
		for slotId in table.clone(list) do
			removeSpawned(plot, slotId)
		end
	end
	if data == nil then
		return
	end
	for slotId, defenderType in data.Restaurant.Defense do
		spawnDefender(plot, slotId, defenderType)
	end
end

local function respawnFallen()
	local now = os.clock()
	for plot, list in spawned do
		for slotId, entry in table.clone(list) do
			if isAlive(entry.model) then
				entry.deadSince = nil
			elseif entry.deadSince == nil then
				entry.deadSince = now
			elseif now - entry.deadSince >= RESPAWN_DELAY and not PlotService:isInCombat(plot) then
				spawnDefender(plot, slotId, entry.defenderType)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Нанять защитника в слот своего ресторана. Возвращает true при успехе.
function DefenseService:hire(player: Player, slotId: string, defenderType: string): boolean
	local plot = PlotService:getPlot(player)
	local data = DataService:get(player)
	local info = Defense[defenderType]
	if plot == nil or data == nil or info == nil then
		return false
	end
	if PlotService:isInCombat(plot) then
		NetService:notify(player, "Нельзя нанимать охрану во время атаки")
		return false
	end
	local slot = findSlot(plot, slotId)
	if slot == nil then
		NetService:notify(player, `В ресторане нет слота «{slotId}»`)
		return false
	end
	if slot:GetAttribute("SlotKind") ~= info.Kind then
		NetService:notify(player, `Слот «{slotId}» не подходит для «{info.Name}»`)
		return false
	end
	if plot.tier < info.MinTier then
		NetService:notify(player, `«{info.Name}» доступен с {info.MinTier} уровня ресторана`)
		return false
	end
	if data.Restaurant.Defense[slotId] ~= nil then
		NetService:notify(player, `Слот «{slotId}» уже занят`)
		return false
	end
	if data.Cash < info.Cost then
		NetService:notify(player, `«{info.Name}» стоит ${info.Cost}`)
		return false
	end

	-- Проверка и списание без yield между ними.
	DataService:increment(player, "Cash", -info.Cost)
	DataService:update(player, "Restaurant", function(restaurant)
		restaurant.Defense[slotId] = defenderType
		return restaurant
	end)
	spawnDefender(plot, slotId, defenderType)
	NetService:notify(player, `Нанят: {info.Name} ({slotId})`)
	return true
end

-- Уволить защитника из слота. Возвращается половина цены.
function DefenseService:dismiss(player: Player, slotId: string): boolean
	local plot = PlotService:getPlot(player)
	local data = DataService:get(player)
	if plot == nil or data == nil then
		return false
	end
	local defenderType = data.Restaurant.Defense[slotId]
	local info = if defenderType then Defense[defenderType] else nil
	if defenderType == nil or info == nil then
		NetService:notify(player, `Слот «{slotId}» пуст`)
		return false
	end
	DataService:update(player, "Restaurant", function(restaurant)
		restaurant.Defense[slotId] = nil
		return restaurant
	end)
	local refund = math.floor(info.Cost * DISMISS_REFUND)
	DataService:increment(player, "Cash", refund)
	removeSpawned(plot, slotId)
	NetService:notify(player, `Уволен: {info.Name}, возвращено ${refund}`)
	return true
end

-- Слоты текущего ресторана игрока: { {id, kind, occupant} }.
function DefenseService:getSlots(player: Player): { { id: string, kind: string, occupant: string? } }
	local plot = PlotService:getPlot(player)
	local data = DataService:get(player)
	local result = {}
	if plot == nil or data == nil or plot.restaurant == nil then
		return result
	end
	for _, descendant in plot.restaurant:GetDescendants() do
		if CollectionService:HasTag(descendant, SLOT_TAG) then
			local id = descendant:GetAttribute("SlotId")
			local kind = descendant:GetAttribute("SlotKind")
			if typeof(id) == "string" and typeof(kind) == "string" then
				table.insert(result, { id = id, kind = kind, occupant = data.Restaurant.Defense[id] })
			end
		end
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function DefenseService:Init()
	templates = ServerStorage:FindFirstChild(TEMPLATES_FOLDER)
	if templates == nil then
		warn(`[DefenseService] Нет папки ServerStorage.{TEMPLATES_FOLDER} с охраной`)
	end
end

function DefenseService:Start()
	PlotService:onRestaurantBuilt(function(plot: Plot)
		spawnAll(plot)
	end)
	PlotService.PlotReleased:Connect(function(_, plot: Plot)
		spawned[plot] = nil -- модели удалил PlotService вместе с папкой Defense
	end)

	NetService:on("HireDefender", {
		args = { Guard.string(32), Guard.keyOf(Defense) },
		rate = 2,
		burst = 4,
	}, function(player: Player, slotId: string, defenderType: string)
		DefenseService:hire(player, slotId, defenderType)
	end)
	NetService:on("DismissDefender", {
		args = { Guard.string(32) },
		rate = 2,
		burst = 4,
	}, function(player: Player, slotId: string)
		DefenseService:dismiss(player, slotId)
	end)

	task.spawn(function()
		while true do
			task.wait(RESPAWN_CHECK_INTERVAL)
			xpcall(respawnFallen, function(message: any)
				warn(
					`[DefenseService] Ошибка возрождения охраны: {message}\n{debug.traceback()}`
				)
			end)
		end
	end)
end

return DefenseService
