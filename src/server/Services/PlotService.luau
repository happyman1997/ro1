--!strict
--[[
	PlotService — участки (Plot) и рестораны на них.

	• При загрузке данных игрок получает свободный участок, на нём строится
	  ресторан его уровня. При выходе участок очищается.
	• Улучшение и ремонт = замена модели ресторана целиком (buildRestaurant).
	• Даёт остальным сервисам: владельца участка, проверку «внутри территории»,
	  метку «база под атакой».

	Модель уровня берётся из ServerStorage.Restaurants (а не ReplicatedStorage):
	шаблоны не скачиваются каждому клиенту при входе, а клиент получает только
	ту копию, что реально стоит на карте. Структура — docs/ARCHITECTURE.md.

	Участок в Workspace — Model с тегом "Plot":
		Origin    (Part) — точка, куда ставится пивот модели ресторана
		Territory (Part) — объём территории: охрана защищает всё, что внутри
		Spawn     (SpawnLocation, необязательно) — точка появления владельца
		Defense   (Folder, создаётся сам) — нанятая охрана вне модели ресторана
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataTemplate = require(ReplicatedStorage.Shared.DataTemplate)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Tiers = require(ReplicatedStorage.Shared.Config.Tiers)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)

local PLOT_TAG = "Plot"
local TEMPLATES_FOLDER = "Restaurants"
-- Сколько секунд после последнего боя база считается «под атакой».
-- Под атакой нельзя улучшать и чинить ресторан: замена модели восстанавливает
-- стены и персонал, это был бы бесплатный мгновенный ремонт посреди штурма.
local COMBAT_COOLDOWN = 20

export type Plot = {
	id: string,
	model: Model,
	origin: BasePart,
	territory: BasePart,
	defenseFolder: Folder,
	owner: Player?,
	tier: number,
	restaurant: Model?,
	lastCombatAt: number, -- os.clock() последнего боя на территории
}

local PlotService = {}

-- (player, plot) — игроку выдан участок, ресторан построен.
PlotService.PlotAssigned = Signal.new() :: Signal.Signal<Player, Plot>
-- (player, plot) — участок освобождён (игрок вышел).
PlotService.PlotReleased = Signal.new() :: Signal.Signal<Player, Plot>
-- (plot, restaurant) — на участке появилась новая модель ресторана.
PlotService.RestaurantBuilt = Signal.new() :: Signal.Signal<Plot, Model>
-- (plot, restaurant) — модель ресторана сейчас будет удалена.
PlotService.RestaurantRemoving = Signal.new() :: Signal.Signal<Plot, Model>

local plots: { Plot } = {}
local plotByModel: { [Instance]: Plot } = {}
local plotByPlayer: { [Player]: Plot } = {}
local templates: Instance? = nil

--------------------------------------------------------------------------------
-- Внутреннее
--------------------------------------------------------------------------------

local function isInsidePart(part: BasePart, position: Vector3): boolean
	local localPosition = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	return math.abs(localPosition.X) <= half.X
		and math.abs(localPosition.Y) <= half.Y
		and math.abs(localPosition.Z) <= half.Z
end

-- Служебная деталь: невидима, не мешает ходить, стрелять и лучам охраны.
local function makeHelperPart(part: BasePart)
	part.Anchored = true
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
end

local function registerPlot(instance: Instance)
	if not instance:IsA("Model") then
		warn(`[PlotService] Тег {PLOT_TAG} должен быть на Model: {instance:GetFullName()}`)
		return
	end
	local model = instance :: Model
	local origin = model:FindFirstChild("Origin")
	local territory = model:FindFirstChild("Territory")
	if not (origin and origin:IsA("BasePart") and territory and territory:IsA("BasePart")) then
		warn(`[PlotService] {model:GetFullName()}: нужны детали Origin и Territory`)
		return
	end
	local originPart = origin :: BasePart
	local territoryPart = territory :: BasePart
	makeHelperPart(originPart)
	makeHelperPart(territoryPart)

	local defenseFolder: Folder
	local existingDefense = model:FindFirstChild("Defense")
	if existingDefense and existingDefense:IsA("Folder") then
		defenseFolder = existingDefense :: Folder
	else
		defenseFolder = Instance.new("Folder")
		defenseFolder.Name = "Defense"
		defenseFolder.Parent = model
	end

	local plot: Plot = {
		id = model.Name,
		model = model,
		origin = originPart,
		territory = territoryPart,
		defenseFolder = defenseFolder,
		owner = nil,
		tier = 1,
		restaurant = nil,
		lastCombatAt = -math.huge,
	}
	table.insert(plots, plot)
	plotByModel[model] = plot
end

local function removeRestaurant(plot: Plot)
	local restaurant = plot.restaurant
	if restaurant == nil then
		return
	end
	PlotService.RestaurantRemoving:Fire(plot, restaurant)
	plot.restaurant = nil
	restaurant:Destroy()
end

-- Поставить на участок модель уровня tier вместо текущей.
-- Между удалением старой и появлением новой нет yield, поэтому «пустого
-- кадра» без здания игроки не увидят.
local function buildRestaurant(plot: Plot, tier: number)
	local info = Tiers[tier]
	local template = if templates then templates:FindFirstChild(info.Model) else nil
	if template == nil or not template:IsA("Model") then
		warn(`[PlotService] Нет модели ServerStorage.{TEMPLATES_FOLDER}.{info.Model}`)
		return
	end

	local restaurant = (template :: Model):Clone()
	restaurant.Name = "Restaurant"
	restaurant:PivotTo(plot.origin.CFrame)

	removeRestaurant(plot)
	restaurant.Parent = plot.model
	plot.restaurant = restaurant
	plot.tier = tier
	plot.model:SetAttribute("Tier", tier)

	PlotService.RestaurantBuilt:Fire(plot, restaurant)
end

local function assign(player: Player, data: DataTemplate.PlayerData)
	if plotByPlayer[player] then
		return
	end
	local free: Plot? = nil
	for _, plot in plots do
		if plot.owner == nil then
			free = plot
			break
		end
	end
	if free == nil then
		if #plots == 0 then
			return -- карта ещё не размечена (тест в пустом месте): играем без участка
		end
		warn("[PlotService] Нет свободных участков: Players.MaxPlayers должен быть не больше числа участков")
		player:Kick("На сервере нет свободных участков. Зайдите на другой сервер.")
		return
	end

	free.owner = player
	free.lastCombatAt = -math.huge
	plotByPlayer[player] = free
	-- Атрибуты нужны клиенту: подсказки кассы, табличка владельца.
	free.model:SetAttribute("OwnerUserId", player.UserId)
	free.model:SetAttribute("OwnerName", player.DisplayName)

	local tier = math.clamp(math.floor(data.Restaurant.Tier), 1, #Tiers)
	buildRestaurant(free, tier)

	local spawn = free.model:FindFirstChild("Spawn")
	if spawn and spawn:IsA("SpawnLocation") then
		player.RespawnLocation = spawn
		local character = player.Character
		if character then
			character:PivotTo(spawn.CFrame + Vector3.new(0, 4, 0))
		end
	end

	PlotService.PlotAssigned:Fire(player, free)
end

local function release(player: Player)
	local plot = plotByPlayer[player]
	if plot == nil then
		return
	end
	plotByPlayer[player] = nil
	-- Владельца снимаем первым: обработчики RestaurantRemoving по plot.owner == nil
	-- понимают, что это уход игрока, а не перестройка.
	plot.owner = nil
	removeRestaurant(plot)
	plot.defenseFolder:ClearAllChildren()
	plot.model:SetAttribute("OwnerUserId", nil)
	plot.model:SetAttribute("OwnerName", nil)
	plot.model:SetAttribute("Tier", nil)
	PlotService.PlotReleased:Fire(player, plot)
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

function PlotService:getPlot(player: Player): Plot?
	return plotByPlayer[player]
end

-- Участок, которому принадлежит объект (ищется по предкам).
function PlotService:getPlotFromInstance(instance: Instance): Plot?
	local node: Instance? = instance
	while node do
		local plot = plotByModel[node]
		if plot then
			return plot
		end
		node = node.Parent
	end
	return nil
end

-- Участок, на территории которого находится точка.
function PlotService:getPlotAt(position: Vector3): Plot?
	for _, plot in plots do
		if isInsidePart(plot.territory, position) then
			return plot
		end
	end
	return nil
end

function PlotService:isInTerritory(plot: Plot, position: Vector3): boolean
	return isInsidePart(plot.territory, position)
end

function PlotService:isOwner(plot: Plot, player: Player): boolean
	return plot.owner == player
end

-- Свой для охраны участка. Сейчас только владелец; сюда же добавятся
-- совладельцы и участники пати.
function PlotService:isFriendly(plot: Plot, player: Player): boolean
	return plot.owner == player
end

-- Отметить бой на территории (вызывают охрана и боевая система).
function PlotService:markCombat(plot: Plot)
	plot.lastCombatAt = os.clock()
end

function PlotService:isInCombat(plot: Plot): boolean
	return os.clock() - plot.lastCombatAt < COMBAT_COOLDOWN
end

-- Перестроить ресторан текущего уровня (ремонт): новые стены, мебель, персонал.
function PlotService:rebuild(plot: Plot)
	buildRestaurant(plot, plot.tier)
end

-- Вызвать callback для каждого уже построенного ресторана и для будущих.
-- Защищает от гонки «сервис подписался после того, как ресторан построили».
function PlotService:onRestaurantBuilt(callback: (Plot, Model) -> ()): Signal.Connection
	for _, plot in plots do
		local restaurant = plot.restaurant
		if restaurant then
			task.spawn(callback, plot, restaurant)
		end
	end
	return PlotService.RestaurantBuilt:Connect(callback)
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function PlotService:Init()
	templates = ServerStorage:FindFirstChild(TEMPLATES_FOLDER)
	if templates == nil then
		warn(`[PlotService] Нет папки ServerStorage.{TEMPLATES_FOLDER} с моделями уровней`)
	end

	for _, instance in CollectionService:GetTagged(PLOT_TAG) do
		registerPlot(instance)
	end
	-- Стабильный порядок выдачи: Plot1, Plot2, ...
	table.sort(plots, function(a: Plot, b: Plot)
		return a.id < b.id
	end)
	if #plots == 0 then
		warn(`[PlotService] На карте нет моделей с тегом {PLOT_TAG}`)
	end
end

function PlotService:Start()
	DataService:onLoaded(assign)
	Players.PlayerRemoving:Connect(release)

	NetService:on("UpgradeRestaurant", { args = {}, rate = 1, burst = 2 }, function(player: Player)
		local plot = plotByPlayer[player]
		local data = DataService:get(player)
		if plot == nil or data == nil then
			return
		end
		local nextTier = plot.tier + 1
		local info = Tiers[nextTier]
		if info == nil then
			NetService:notify(player, "Ресторан уже максимального уровня")
			return
		end
		if PlotService:isInCombat(plot) then
			NetService:notify(player, "Нельзя улучшать ресторан во время атаки")
			return
		end
		if data.Cash < info.UpgradeCost then
			NetService:notify(player, `Улучшение стоит ${info.UpgradeCost}`)
			return
		end

		-- Проверка и списание без yield между ними: двойного списания или
		-- двойного улучшения при пачке одинаковых запросов не будет.
		DataService:increment(player, "Cash", -info.UpgradeCost)
		DataService:update(player, "Restaurant", function(restaurant)
			restaurant.Tier = nextTier
			return restaurant
		end)
		buildRestaurant(plot, nextTier)
		NetService:notify(player, `Ресторан улучшен: {info.Name}`)
	end)
end

return PlotService
