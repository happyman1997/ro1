--!strict
--[[
	RestaurantService — экономика ресторана: доход и остановка при разрушении.

	• Пока ресторан «работает», каждые INCOME_INTERVAL секунд в кассу идёт
	  доход уровня (Tiers[tier].IncomePerSecond). Доход считает сервер, а не NPC:
	  если клиент-NPC застрянет в двери, экономика не сломается. NPC-клиенты
	  и официанты — визуальный слой, который будет вызывать deposit по заказам.
	• Ресторан работает, только если весь персонал жив и вся мебель цела:
	  - персонал: модели с тегом "Staff" и Humanoid внутри модели ресторана;
	  - мебель: объекты с тегом "Furniture"; сломанная — атрибут Broken = true
	    (его ставит боевая система, когда здоровье мебели падает до нуля)
	    или объект удалён.
	• Ремонт (RepairRestaurant) — платная перестройка модели текущего уровня.
	  Запрещён во время атаки (PlotService:isInCombat).

	ЗАЩИТА:
	• Персонал принадлежит серверу физически (NpcUtil), иначе эксплойт мог бы
	  «убить» повара, утащив его модель, а не в бою.
	• «Сломан» сохраняется в данных (Restaurant.NeedsRepair). Без этого выход
	  и перезаход строили бы ресторан целым, то есть ремонт был бы бесплатным.
	  Улучшение уровня тоже не снимает поломку: новый уровень надо починить.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tiers = require(ReplicatedStorage.Shared.Config.Tiers)
local NpcUtil = require(script.Parent.Parent.Modules.NpcUtil)
local CashRegisterService = require(script.Parent.CashRegisterService)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local STAFF_TAG = "Staff"
local FURNITURE_TAG = "Furniture"
local INCOME_INTERVAL = 2 -- секунд

type Plot = PlotService.Plot

type State = {
	staff: { Humanoid },
	furniture: { Instance },
	needsRepair: boolean, -- сломан с прошлой сессии или до улучшения
	operational: boolean,
}

local RestaurantService = {}

local states: { [Plot]: State } = {}

local function saveNeedsRepair(plot: Plot, value: boolean)
	local owner = plot.owner
	if owner and DataService:isLoaded(owner) then
		DataService:update(owner, "Restaurant", function(restaurant)
			restaurant.NeedsRepair = value
			return restaurant
		end)
	end
end

local function checkOperational(plot: Plot, state: State): boolean
	local restaurant = plot.restaurant
	if restaurant == nil or state.needsRepair then
		return false
	end
	for _, humanoid in state.staff do
		if humanoid.Health <= 0 or not humanoid:IsDescendantOf(restaurant) then
			return false
		end
	end
	for _, furniture in state.furniture do
		if furniture:GetAttribute("Broken") == true or not furniture:IsDescendantOf(restaurant) then
			return false
		end
	end
	return true
end

local function setOperational(plot: Plot, state: State, value: boolean)
	state.operational = value
	plot.model:SetAttribute("Operational", value)
	if not value then
		state.needsRepair = true
		saveNeedsRepair(plot, true)
		local owner = plot.owner
		if owner then
			NetService:notify(
				owner,
				"Ресторан остановлен: персонал убит или мебель сломана. Почините его."
			)
		end
	end
end

local function onRestaurantBuilt(plot: Plot, restaurant: Model)
	local owner = plot.owner
	local data = if owner then DataService:get(owner) else nil
	local needsRepair = data ~= nil and data.Restaurant.NeedsRepair
	local state: State = { staff = {}, furniture = {}, needsRepair = needsRepair, operational = not needsRepair }
	for _, descendant in restaurant:GetDescendants() do
		if CollectionService:HasTag(descendant, STAFF_TAG) and descendant:IsA("Model") then
			local staffModel = descendant :: Model
			local humanoid = staffModel:FindFirstChildOfClass("Humanoid")
			if humanoid then
				table.insert(state.staff, humanoid)
				NpcUtil.claimNetworkOwnership(staffModel)
			end
		elseif CollectionService:HasTag(descendant, FURNITURE_TAG) then
			table.insert(state.furniture, descendant)
		end
	end
	states[plot] = state
	plot.model:SetAttribute("Operational", state.operational)
	if owner and needsRepair then
		NetService:notify(
			owner,
			"Ресторан всё ещё сломан и не приносит доход. Почините его."
		)
	end
end

local function tickIncome()
	for plot, state in states do
		if plot.owner == nil then
			continue
		end
		local operational = checkOperational(plot, state)
		if operational ~= state.operational then
			setOperational(plot, state, operational)
		end
		if operational then
			CashRegisterService:deposit(plot, Tiers[plot.tier].IncomePerSecond * INCOME_INTERVAL)
		end
	end
end

function RestaurantService:isOperational(plot: Plot): boolean
	local state = states[plot]
	return state ~= nil and state.operational
end

function RestaurantService:Start()
	PlotService:onRestaurantBuilt(onRestaurantBuilt)
	PlotService.RestaurantRemoving:Connect(function(plot: Plot)
		states[plot] = nil
	end)

	NetService:on("RepairRestaurant", { args = {}, rate = 1, burst = 2 }, function(player: Player)
		local plot = PlotService:getPlot(player)
		local data = DataService:get(player)
		local state = if plot then states[plot] else nil
		if plot == nil or data == nil or state == nil then
			return
		end
		if checkOperational(plot, state) then
			NetService:notify(player, "Ресторан в порядке, ремонт не нужен")
			return
		end
		if PlotService:isInCombat(plot) then
			NetService:notify(player, "Нельзя чинить ресторан во время атаки")
			return
		end
		local cost = Tiers[plot.tier].RepairCost
		if data.Cash < cost then
			NetService:notify(player, `Ремонт стоит ${cost}`)
			return
		end

		DataService:increment(player, "Cash", -cost)
		saveNeedsRepair(plot, false) -- до перестройки: onRestaurantBuilt читает этот флаг
		PlotService:rebuild(plot) -- новая модель: целые стены, мебель, живой персонал
		NetService:notify(player, "Ресторан отремонтирован")
	end)

	task.spawn(function()
		while true do
			task.wait(INCOME_INTERVAL)
			xpcall(tickIncome, function(message: any)
				warn(
					`[RestaurantService] Ошибка начисления дохода: {message}\n{debug.traceback()}`
				)
			end)
		end
	end)
end

return RestaurantService
