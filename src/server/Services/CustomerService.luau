--!strict
--[[
	CustomerService — NPC-клиенты ресторана. Это визуальный слой: доход
	считает RestaurantService сам по себе, клиенты только показывают, что
	ресторан живёт.

	Маршрут (точки в модели уровня, папка CustomerPoints):
	  CustomerSpawn (под козырьком) → CustomerDoor (у входа) → CustomerOrder
	  (место у стойки) → постоять у стойки → обратно к случайному CustomerSpawn.
	Одновременно клиентов не больше MaxCustomers уровня и свободных мест у стойки.

	• Ресторан стоит (сломан) или под атакой — новые клиенты не приходят,
	  а те, что уже идут, разворачиваются; при атаке — убегают бегом.
	• Клиента можно убить пулей или взрывом. Это ничего не даёт и ничего не
	  ломает: $0, доход не останавливается, тревоги нет. Свой ресторан и
	  ресторан союзника этим не задеть (проверяет вызывающий сервис).

	Движение — Tween по прямым отрезкам: один Tween на деталь на отрезок,
	без физики и без Humanoid. Сервер сам знает, где клиент на отрезке
	(по времени), и не читает положение деталей посреди анимации.

	ЗАЩИТА:
	• Клиенты не служат живым щитом: у их деталей ShootThrough и SeeThrough,
	  пули и взгляд охраны проходят насквозь. Убитый клиент сразу перестаёт
	  ловить лучи (CanQuery = false).
	• Снайпер не заработает и не навредит, убивая клиентов на улице: $0, доход
	  не зависит от клиентов, участок не помечается «в бою» (иначе стрельбой по
	  клиентам можно было бы запрещать владельцу ремонт и улучшение).
	• Детали заякорены и без столкновений: толкать клиентов физикой нельзя,
	  и сетевого владения у них нет.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Tiers = require(ReplicatedStorage.Shared.Config.Tiers)
local Destruction = require(script.Parent.Parent.Modules.Destruction)
local PlotService = require(script.Parent.PlotService)

type Plot = PlotService.Plot

local TICK = 0.25 -- секунд между проходами цикла
local SPAWN_INTERVAL = 4 -- не чаще одного нового клиента на ресторан за столько секунд
local WALK_SPEED = 7
local RUN_SPEED = 16
local ORDER_TIME_MIN = 3
local ORDER_TIME_MAX = 6
local CORPSE_TIME = 3 -- секунд лежит убитый клиент

local SHIRT_COLORS = {
	Color3.fromRGB(196, 40, 28),
	Color3.fromRGB(13, 105, 172),
	Color3.fromRGB(75, 151, 75),
	Color3.fromRGB(245, 205, 48),
	Color3.fromRGB(107, 50, 124),
	Color3.fromRGB(218, 133, 65),
}
local SKIN_COLORS = {
	Color3.fromRGB(255, 204, 153),
	Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(124, 92, 70),
}

type State = "Arriving" | "Ordering" | "Leaving" | "Dead"

type Customer = {
	model: Model,
	plot: Plot,
	parts: { BasePart },
	offsets: { CFrame }, -- положение деталей относительно «ног» клиента
	tweens: { Tween },
	state: State,
	route: { Vector3 }, -- точки маршрута; клиент идёт к route[target]
	target: number,
	segmentFrom: CFrame,
	segmentTo: CFrame,
	segmentStart: number,
	segmentEnd: number,
	speed: number,
	spot: BasePart?, -- занятое место у стойки
	waitUntil: number, -- до какого времени стоит у стойки / лежит
}

type PlotState = {
	customers: { Customer },
	folder: Folder,
	nextSpawnAt: number,
}

local CustomerService = {}

local random = Random.new()
local plotStates: { [Plot]: PlotState } = {}
local customerByModel: { [Model]: Customer } = {}

--------------------------------------------------------------------------------
-- Модель клиента
--------------------------------------------------------------------------------

local function newPart(name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = true
	part.Material = Enum.Material.SmoothPlastic
	-- Не живой щит: пули и взгляд охраны проходят сквозь клиента.
	part:SetAttribute("ShootThrough", true)
	part:SetAttribute("SeeThrough", true)
	return part
end

local function buildModel(folder: Folder, feet: CFrame): (Model, { BasePart }, { CFrame })
	local model = Instance.new("Model")
	model.Name = "Customer"
	local torso = newPart("Torso", Vector3.new(2, 3, 1), SHIRT_COLORS[random:NextInteger(1, #SHIRT_COLORS)])
	local head = newPart("Head", Vector3.new(1.1, 1.1, 1.1), SKIN_COLORS[random:NextInteger(1, #SKIN_COLORS)])
	local parts: { BasePart } = { torso, head }
	local offsets = { CFrame.new(0, 1.5, 0), CFrame.new(0, 3.6, 0) }
	for index, part in parts do
		part.CFrame = feet * offsets[index]
		part.Parent = model
	end
	model.PrimaryPart = torso
	model.WorldPivot = feet
	CollectionService:AddTag(model, "Customer")
	model.Parent = folder
	return model, parts, offsets
end

--------------------------------------------------------------------------------
-- Движение
--------------------------------------------------------------------------------

local function stopTweens(customer: Customer)
	for _, tween in customer.tweens do
		tween:Cancel()
	end
	table.clear(customer.tweens)
end

-- Где клиент сейчас (по времени на текущем отрезке).
local function currentFeet(customer: Customer): CFrame
	local duration = customer.segmentEnd - customer.segmentStart
	if duration <= 0 then
		return customer.segmentTo
	end
	local alpha = math.clamp((os.clock() - customer.segmentStart) / duration, 0, 1)
	return customer.segmentFrom:Lerp(customer.segmentTo, alpha)
end

local function placeAt(customer: Customer, feet: CFrame)
	for index, part in customer.parts do
		part.CFrame = feet * customer.offsets[index]
	end
	customer.model.WorldPivot = feet
end

-- Повернуть «ноги» лицом по горизонтали в сторону direction.
local function facing(position: Vector3, direction: Vector3, fallback: CFrame): CFrame
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return CFrame.new(position) * fallback.Rotation
	end
	return CFrame.lookAt(position, position + flat)
end

-- Начать отрезок к route[target]. false — маршрут закончился.
local function startSegment(customer: Customer): boolean
	local goal: Vector3? = customer.route[customer.target]
	if goal == nil then
		return false
	end
	local from = currentFeet(customer)
	stopTweens(customer)
	placeAt(customer, from)
	local to = facing(goal, goal - from.Position, from)
	local duration = (goal - from.Position).Magnitude / customer.speed
	customer.segmentFrom = from
	customer.segmentTo = to
	customer.segmentStart = os.clock()
	customer.segmentEnd = os.clock() + duration
	local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)
	for index, part in customer.parts do
		local tween = TweenService:Create(part, info, { CFrame = to * customer.offsets[index] })
		table.insert(customer.tweens, tween)
		tween:Play()
	end
	return true
end

local function remove(customer: Customer)
	stopTweens(customer)
	customerByModel[customer.model] = nil
	customer.model:Destroy()
	local state = plotStates[customer.plot]
	if state then
		local index = table.find(state.customers, customer)
		if index then
			table.remove(state.customers, index)
		end
	end
end

local function freeSpot(customer: Customer)
	customer.spot = nil
end

-- Уйти: развернуться и идти назад по пройденному маршруту к выходу.
local function sendAway(customer: Customer, speed: number)
	if customer.state == "Leaving" or customer.state == "Dead" then
		if customer.state == "Leaving" and speed > customer.speed then
			customer.speed = speed
			startSegment(customer) -- побежать с текущего места
		end
		return
	end
	local back = {}
	local last = if customer.state == "Ordering" then #customer.route else customer.target - 1
	for index = last, 1, -1 do
		table.insert(back, customer.route[index])
	end
	if customer.state == "Ordering" then
		table.remove(back, 1) -- место у стойки — там он уже стоит
	end
	freeSpot(customer)
	customer.state = "Leaving"
	customer.route = back
	customer.target = 1
	customer.speed = speed
	if not startSegment(customer) then
		remove(customer) -- идти некуда (стоял у самого выхода)
	end
end

--------------------------------------------------------------------------------
-- Появление
--------------------------------------------------------------------------------

local function tagged(restaurant: Model, tag: string): { BasePart }
	local list = {}
	for _, descendant in restaurant:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, tag) then
			table.insert(list, descendant)
		end
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

local function isOpen(plot: Plot): boolean
	return plot.owner ~= nil
		and plot.restaurant ~= nil
		and plot.model:GetAttribute("Operational") ~= false
		and not PlotService:isInCombat(plot)
end

local function trySpawn(plot: Plot, state: PlotState)
	local restaurant = plot.restaurant
	local tier = Tiers[plot.tier]
	if restaurant == nil or tier == nil or #state.customers >= tier.MaxCustomers then
		return
	end
	local spawns = tagged(restaurant, "CustomerSpawn")
	local door: BasePart? = tagged(restaurant, "CustomerDoor")[1]
	if #spawns == 0 or door == nil then
		return
	end
	local taken = {}
	for _, customer in state.customers do
		if customer.spot then
			taken[customer.spot] = true
		end
	end
	local free = {}
	for _, spot in tagged(restaurant, "CustomerOrder") do
		if not taken[spot] then
			table.insert(free, spot)
		end
	end
	if #free == 0 then
		return
	end
	local spot = free[random:NextInteger(1, #free)]
	local start = spawns[random:NextInteger(1, #spawns)].Position
	local feet = facing(start, door.Position - start, CFrame.new())
	local model, parts, offsets = buildModel(state.folder, feet)
	local customer: Customer = {
		model = model,
		plot = plot,
		parts = parts,
		offsets = offsets,
		tweens = {},
		state = "Arriving",
		route = { start, door.Position, spot.Position },
		target = 2,
		segmentFrom = feet,
		segmentTo = feet,
		segmentStart = os.clock(),
		segmentEnd = os.clock(),
		speed = WALK_SPEED,
		spot = spot,
		waitUntil = 0,
	}
	customerByModel[model] = customer
	table.insert(state.customers, customer)
	startSegment(customer)
end

--------------------------------------------------------------------------------
-- Цикл
--------------------------------------------------------------------------------

local function stepCustomer(customer: Customer, now: number)
	if customer.state == "Dead" then
		if now >= customer.waitUntil then
			remove(customer)
		end
		return
	end
	if customer.state == "Ordering" then
		if now >= customer.waitUntil then
			-- Уходит к случайному выходу (может к другому, не к тому, откуда пришёл).
			local restaurant = customer.plot.restaurant
			local spawns = if restaurant then tagged(restaurant, "CustomerSpawn") else {}
			sendAway(customer, WALK_SPEED)
			if #spawns > 0 and #customer.route > 0 then
				customer.route[#customer.route] = spawns[random:NextInteger(1, #spawns)].Position
			end
		end
		return
	end
	if now < customer.segmentEnd then
		return
	end
	-- Отрезок пройден.
	customer.target += 1
	if customer.state == "Arriving" and customer.target > #customer.route then
		customer.state = "Ordering"
		customer.waitUntil = now + random:NextNumber(ORDER_TIME_MIN, ORDER_TIME_MAX)
		-- Встать лицом к стойке (места у стойки повёрнуты к ней).
		local spot = customer.spot
		local feet = customer.segmentTo
		if spot then
			feet = CFrame.new(feet.Position) * spot.CFrame.Rotation
		end
		stopTweens(customer)
		customer.segmentFrom = feet
		customer.segmentTo = feet
		placeAt(customer, feet)
		return
	end
	if not startSegment(customer) then
		remove(customer) -- дошёл до выхода
	end
end

local function step()
	local now = os.clock()
	for plot, state in plotStates do
		local open = isOpen(plot)
		if not open then
			local speed = if PlotService:isInCombat(plot) then RUN_SPEED else WALK_SPEED
			for _, customer in table.clone(state.customers) do
				sendAway(customer, speed)
			end
		end
		for _, customer in table.clone(state.customers) do
			stepCustomer(customer, now)
		end
		if open and now >= state.nextSpawnAt then
			state.nextSpawnAt = now + SPAWN_INTERVAL * random:NextNumber(0.75, 1.25)
			trySpawn(plot, state)
		end
	end
end

local function clearPlot(plot: Plot)
	local state = plotStates[plot]
	if state == nil then
		return
	end
	for _, customer in table.clone(state.customers) do
		remove(customer)
	end
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Пуля или взрыв задели деталь. true — это клиент (дальше деталь не обрабатывать).
function CustomerService:hit(part: Instance): boolean
	local model = Destruction.findTaggedAncestor(part, { "Customer" })
	local customer = if model and model:IsA("Model") then customerByModel[model :: Model] else nil
	if customer == nil then
		return model ~= nil
	end
	if customer.state == "Dead" then
		return true
	end
	local feet = currentFeet(customer)
	stopTweens(customer)
	freeSpot(customer)
	customer.state = "Dead"
	customer.waitUntil = os.clock() + CORPSE_TIME
	-- Упал навзничь.
	placeAt(customer, feet * CFrame.new(0, 0.5, 0) * CFrame.Angles(-math.pi / 2, 0, 0))
	for _, bodyPart in customer.parts do
		bodyPart.CanQuery = false
		bodyPart.Color = bodyPart.Color:Lerp(Color3.new(0, 0, 0), 0.4)
	end
	return true
end

-- Клиенты ресторана (для тестов и других систем).
function CustomerService:getCustomers(plot: Plot): { Model }
	local state = plotStates[plot]
	local list = {}
	if state then
		for _, customer in state.customers do
			if customer.state ~= "Dead" then
				table.insert(list, customer.model)
			end
		end
	end
	return list
end

-- Состояние клиента: "Arriving" | "Ordering" | "Leaving" | "Dead" (nil — не клиент).
function CustomerService:getState(model: Model): string?
	local customer = customerByModel[model]
	return if customer then customer.state else nil
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function CustomerService:Start()
	PlotService:onRestaurantBuilt(function(plot: Plot)
		local state = plotStates[plot]
		if state == nil then
			local folder = Instance.new("Folder")
			folder.Name = "Customers"
			folder.Parent = plot.model
			state = { customers = {}, folder = folder, nextSpawnAt = 0 }
			plotStates[plot] = state
		end
		-- Новая модель — новые точки маршрута: старые клиенты исчезают.
		clearPlot(plot)
		state.nextSpawnAt = os.clock() + 1
	end)
	PlotService.PlotReleased:Connect(function(_, plot: Plot)
		clearPlot(plot)
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			-- Ошибка в одном проходе не должна навсегда остановить клиентов.
			xpcall(step, function(message: any)
				warn(`[Customers] Ошибка прохода: {message}\n{debug.traceback()}`)
			end)
		end
	end)
end

return CustomerService
