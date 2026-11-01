--!strict
--[[
	CashRegisterService — касса ресторана.

	• Выручка копится в кассе (deposit) до лимита уровня. Это состояние сессии:
	  оно живёт в памяти сервера и при выходе владельца не сохраняется.
	• Владелец подходит и забирает выручку: подсказка «Забрать выручку» (E).
	• Разведчик взламывает чужую кассу: подсказка «Взломать» (F) запускает
	  СЕРВЕРНЫЙ таймер (Tiers[tier].HackDuration). Пока идёт взлом, вор
	  не замаскирован: охрана, которая его видит, открывает огонь.

	Взлом срывается, если вор: погиб, вышел, отошёл от кассы, достал оружие,
	был раскрыт или его увидел владелец в радиусе CATCH_RADIUS («пойман»).
	При поимке или с оружием в руках маскировка слетает на EXPOSE_ON_FAIL секунд.
	Успех: вор получает STEAL_FRACTION содержимого, касса защищена
	REGISTER_COOLDOWN секунд, вор не может взламывать THIEF_COOLDOWN секунд.

	ЗАЩИТА ОТ ЧИТОВ:
	• HoldDuration у ProximityPrompt считает клиент — эксплойт срабатывает
	  мгновенно (fireproximityprompt). Поэтому длительность взлома отсчитывает
	  только сервер, а подсказка лишь даёт сигнал «начать».
	• Расстояние до кассы проверяет сервер при каждом запросе и на протяжении
	  всего взлома: срабатывание подсказки издалека отклоняется.
	• Роль проверяет сервер: чужую кассу не забрать, не-разведчик не взломает.
	  То, что клиент прячет «лишние» подсказки, — только удобство.
	• Частота срабатываний ограничена (RateLimiter), нарушения идут в анти-чит.
	• Сумма в кассе хранится только на сервере. Атрибут Cash на кассе — витрина:
	  его изменение на клиенте ни на что не влияет.
	• Деньги списываются из кассы и зачисляются игроку без yield между проверкой
	  и записью: «двойной сбор» пачкой запросов невозможен.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Tiers = require(ReplicatedStorage.Shared.Config.Tiers)
local LineOfSight = require(script.Parent.Parent.Modules.LineOfSight)
local RateLimiter = require(script.Parent.Parent.Modules.RateLimiter)
local ClassService = require(script.Parent.ClassService)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local REGISTER_TAG = "CashRegister" -- деталь или модель кассы внутри модели ресторана
local PROMPT_TAG = "RegisterPrompt" -- по нему клиент находит подсказки кассы

local PROMPT_DISTANCE = 8 -- дальность подсказки на клиенте
local INTERACT_DISTANCE = 12 -- серверный предел (с запасом на пинг)
local HACK_LEASH_DISTANCE = 12 -- во время взлома нельзя отходить дальше
local CATCH_RADIUS = 18 -- владелец ближе и видит вора — вор пойман
local STEAL_FRACTION = 0.75 -- доля кассы, которую уносит вор
local MIN_LOOT = 50 -- меньше — взлом не начинается
local OWNER_ALERT_DELAY = 2 -- через сколько секунд взлома владельцу приходит тревога
local REGISTER_COOLDOWN = 90 -- после успешного взлома касса защищена
local THIEF_COOLDOWN = 30 -- пауза между взломами для одного вора
local EXPOSE_ON_FAIL = 20 -- раскрытие вора при поимке
local HACK_TICK = 0.2

type Plot = PlotService.Plot

type Register = {
	part: BasePart,
	prompts: { ProximityPrompt },
	connections: { RBXScriptConnection },
}

type Hack = {
	thief: Player,
	startedAt: number,
	endsAt: number,
	ownerAlerted: boolean,
}

local CashRegisterService = {}

local cash: { [Plot]: number } = {}
local registers: { [Plot]: Register } = {}
local hacks: { [Plot]: Hack } = {}
local hackingPlotOf: { [Player]: Plot } = {}
local registerCooldownUntil: { [Plot]: number } = {}
local thiefCooldownUntil: { [Player]: number } = {}
local promptLimiter = RateLimiter.new(2, 4)

--------------------------------------------------------------------------------
-- Касса и витрина
--------------------------------------------------------------------------------

local function updateDisplay(plot: Plot)
	local register = registers[plot]
	if register then
		register.part:SetAttribute("Cash", math.floor(cash[plot] or 0))
		register.part:SetAttribute("Capacity", Tiers[plot.tier].RegisterCapacity)
	end
end

local function distanceToRegister(register: Register, root: BasePart): number
	return (root.Position - register.part.Position).Magnitude
end

--------------------------------------------------------------------------------
-- Взлом
--------------------------------------------------------------------------------

-- Снять состояние взлома. Возвращает завершённый взлом (или nil).
local function finishHack(plot: Plot): Hack?
	local hack = hacks[plot]
	if hack == nil then
		return nil
	end
	hacks[plot] = nil
	hackingPlotOf[hack.thief] = nil
	ClassService:setHacking(hack.thief, false)
	return hack
end

local function cancelHack(plot: Plot, reason: string, expose: boolean)
	local hack = finishHack(plot)
	if hack == nil then
		return
	end
	local thief = hack.thief
	if expose then
		ClassService:expose(thief, EXPOSE_ON_FAIL, reason)
	end
	if thief.Parent == Players then
		NetService:fireClient(thief, "HackState", "Ended", false)
		NetService:notify(thief, `Взлом сорван: {reason}`)
	end
	local owner = plot.owner
	if owner and hack.ownerAlerted then
		NetService:notify(owner, `Взлом кассы сорван: {reason}`)
	end
end

local function completeHack(plot: Plot, now: number)
	local hack = finishHack(plot)
	if hack == nil then
		return
	end
	local thief = hack.thief
	local loot = math.floor((cash[plot] or 0) * STEAL_FRACTION)
	registerCooldownUntil[plot] = now + REGISTER_COOLDOWN
	thiefCooldownUntil[thief] = now + THIEF_COOLDOWN
	NetService:fireClient(thief, "HackState", "Ended", loot > 0)

	if loot <= 0 or not DataService:isLoaded(thief) then
		NetService:notify(thief, "Касса оказалась пустой")
		return
	end

	cash[plot] = (cash[plot] or 0) - loot
	updateDisplay(plot)
	DataService:increment(thief, "Cash", loot)
	DataService:update(thief, "Stats", function(stats)
		stats.Robberies += 1
		stats.CashStolen += loot
		return stats
	end)
	NetService:notify(thief, `Касса взломана: +${loot}`)

	local owner = plot.owner
	if owner and DataService:isLoaded(owner) then
		DataService:update(owner, "Stats", function(stats)
			stats.TimesRobbed += 1
			return stats
		end)
		NetService:notify(owner, `{thief.DisplayName} украл из вашей кассы ${loot}!`)
	end
end

-- Можно ли продолжать взлом. Возвращает (причина срыва или nil, раскрыть ли вора).
local function checkHack(plot: Plot, hack: Hack): (string?, boolean)
	local thief = hack.thief
	if thief.Parent ~= Players then
		return "вор покинул игру", false
	end
	local character, _, root = CharacterUtil.getAlive(thief)
	if character == nil or root == nil then
		return "вор погиб", false
	end
	local register = registers[plot]
	if register == nil then
		return "касса исчезла", false
	end
	if distanceToRegister(register, root) > HACK_LEASH_DISTANCE then
		return "вор отошёл от кассы", false
	end
	if CharacterUtil.getEquippedWeapon(character) then
		return "вор достал оружие", true
	end
	if ClassService:isExposed(thief) then
		return "вора раскрыли", false
	end

	-- «Пойман владельцем»: владелец рядом и видит вора.
	local owner = plot.owner
	if owner then
		local ownerCharacter, _, ownerRoot = CharacterUtil.getAlive(owner)
		if ownerCharacter and ownerRoot and (ownerRoot.Position - root.Position).Magnitude <= CATCH_RADIUS then
			local head = ownerCharacter:FindFirstChild("Head")
			local eye = if head and head:IsA("BasePart") then head.Position else ownerRoot.Position
			if LineOfSight.canSee(eye, character, { ownerCharacter }) then
				return "владелец поймал вора", true
			end
		end
	end
	return nil, false
end

local function updateHacks()
	local now = os.clock()
	for plot, hack in table.clone(hacks) do
		if hacks[plot] ~= hack then
			continue -- взлом уже завершён в этом же проходе
		end
		local reason, expose = checkHack(plot, hack)
		if reason then
			cancelHack(plot, reason, expose)
		elseif now >= hack.endsAt then
			completeHack(plot, now)
		elseif not hack.ownerAlerted and now - hack.startedAt >= OWNER_ALERT_DELAY then
			hack.ownerAlerted = true
			local owner = plot.owner
			if owner then
				NetService:notify(owner, "Тревога! Кто-то взламывает вашу кассу!")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Подсказки (ввод от клиента — проверяем как Remote)
--------------------------------------------------------------------------------

local function onCollect(plot: Plot, player: Player)
	if not promptLimiter:check(player) then
		NetService:flag(
			player,
			"слишком частое взаимодействие с кассой",
			NetService.Penalty.RateLimit
		)
		return
	end
	if not PlotService:isOwner(plot, player) then
		-- Честный клиент не показывает эту подсказку у чужой кассы.
		NetService:flag(player, "попытка забрать чужую кассу", NetService.Penalty.RateLimit)
		return
	end
	local register = registers[plot]
	local _, _, root = CharacterUtil.getAlive(player)
	if register == nil or root == nil then
		return
	end
	if distanceToRegister(register, root) > INTERACT_DISTANCE then
		NetService:flag(player, "сбор кассы издалека", NetService.Penalty.BadRequest)
		return
	end

	-- Владелец у кассы во время взлома — вор пойман.
	if hacks[plot] then
		cancelHack(plot, "владелец у кассы", true)
	end

	local amount = math.floor(cash[plot] or 0)
	if amount <= 0 then
		NetService:notify(player, "Касса пуста")
		return
	end
	cash[plot] = (cash[plot] or 0) - amount
	updateDisplay(plot)
	DataService:increment(player, "Cash", amount)
	NetService:notify(player, `Выручка: +${amount}`)
end

local function onHackRequest(plot: Plot, player: Player)
	if not promptLimiter:check(player) then
		NetService:flag(
			player,
			"слишком частое взаимодействие с кассой",
			NetService.Penalty.RateLimit
		)
		return
	end
	if PlotService:isOwner(plot, player) then
		return
	end
	if not ClassService:canHack(player) then
		NetService:flag(player, "взлом кассы не разведчиком", NetService.Penalty.RateLimit)
		return
	end
	local register = registers[plot]
	local _, _, root = CharacterUtil.getAlive(player)
	if register == nil or root == nil or not DataService:isLoaded(player) then
		return
	end
	if distanceToRegister(register, root) > INTERACT_DISTANCE then
		NetService:flag(player, "взлом кассы издалека", NetService.Penalty.BadRequest)
		return
	end
	if hackingPlotOf[player] then
		return
	end
	if hacks[plot] then
		NetService:notify(player, "Эту кассу уже взламывают")
		return
	end
	if not ClassService:isDisguised(player) then
		NetService:notify(
			player,
			"Нужна маскировка: уберите оружие и дождитесь конца раскрытия"
		)
		return
	end

	local now = os.clock()
	local registerWait = (registerCooldownUntil[plot] or 0) - now
	if registerWait > 0 then
		NetService:notify(
			player,
			`Касса недавно взломана, защита снимется через {math.ceil(
				registerWait
			)} с`
		)
		return
	end
	local thiefWait = (thiefCooldownUntil[player] or 0) - now
	if thiefWait > 0 then
		NetService:notify(
			player,
			`Следующий взлом будет доступен через {math.ceil(thiefWait)} с`
		)
		return
	end
	if math.floor((cash[plot] or 0) * STEAL_FRACTION) < MIN_LOOT then
		NetService:notify(player, "В кассе слишком мало денег")
		return
	end

	local duration = Tiers[plot.tier].HackDuration
	hacks[plot] = { thief = player, startedAt = now, endsAt = now + duration, ownerAlerted = false }
	hackingPlotOf[player] = plot
	ClassService:setHacking(player, true) -- с этого момента охрана видит в нём цель
	NetService:fireClient(player, "HackState", "Started", workspace:GetServerTimeNow() + duration)
end

--------------------------------------------------------------------------------
-- Модель кассы
--------------------------------------------------------------------------------

local function removeRegister(plot: Plot)
	local register = registers[plot]
	if register == nil then
		return
	end
	registers[plot] = nil
	for _, connection in register.connections do
		connection:Disconnect()
	end
	for _, prompt in register.prompts do
		prompt:Destroy()
	end
end

local function findRegisterPart(restaurant: Model): BasePart?
	for _, descendant in restaurant:GetDescendants() do
		if CollectionService:HasTag(descendant, REGISTER_TAG) then
			if descendant:IsA("BasePart") then
				return descendant :: BasePart
			elseif descendant:IsA("Model") then
				local model = descendant :: Model
				return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
			end
		end
	end
	return nil
end

local function createPrompt(parent: BasePart, role: string, actionText: string, hold: number, key: Enum.KeyCode)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = role .. "Prompt"
	prompt.ObjectText = "Касса"
	prompt.ActionText = actionText
	prompt.HoldDuration = hold -- только для ощущения; реальное время взлома считает сервер
	prompt.KeyboardKeyCode = key
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Role", role)
	CollectionService:AddTag(prompt, PROMPT_TAG)
	prompt.Parent = parent
	return prompt
end

local function setupRegister(plot: Plot, restaurant: Model)
	removeRegister(plot)
	local part = findRegisterPart(restaurant)
	if part == nil then
		warn(`[CashRegister] В {restaurant:GetFullName()} нет детали с тегом {REGISTER_TAG}`)
		return
	end

	local collectPrompt = createPrompt(part, "Collect", "Забрать выручку", 0.5, Enum.KeyCode.E)
	local hackPrompt = createPrompt(part, "Hack", "Взломать", 0.3, Enum.KeyCode.F)
	registers[plot] = {
		part = part,
		prompts = { collectPrompt, hackPrompt },
		connections = {
			collectPrompt.Triggered:Connect(function(player: Player)
				onCollect(plot, player)
			end),
			hackPrompt.Triggered:Connect(function(player: Player)
				onHackRequest(plot, player)
			end),
		},
	}
	updateDisplay(plot)
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Положить выручку в кассу (единственная точка поступления дохода).
-- Сейчас вызывает RestaurantService по таймеру; система NPC-клиентов будет
-- вызывать его за каждый обслуженный заказ.
function CashRegisterService:deposit(plot: Plot, amount: number)
	if plot.owner == nil or not (amount > 0 and amount < math.huge) then
		return
	end
	local capacity = Tiers[plot.tier].RegisterCapacity
	cash[plot] = math.min(capacity, (cash[plot] or 0) + amount)
	updateDisplay(plot)
end

function CashRegisterService:getCash(plot: Plot): number
	return cash[plot] or 0
end

function CashRegisterService:isBeingHacked(plot: Plot): boolean
	return hacks[plot] ~= nil
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function CashRegisterService:Start()
	PlotService:onRestaurantBuilt(setupRegister)

	PlotService.RestaurantRemoving:Connect(function(plot: Plot)
		local reason = if plot.owner
			then "ресторан перестроен"
			else "владелец покинул игру"
		cancelHack(plot, reason, false)
		removeRegister(plot)
	end)

	PlotService.PlotReleased:Connect(function(_, plot: Plot)
		-- Касса — состояние сессии: при выходе владельца содержимое пропадает.
		cash[plot] = nil
		registerCooldownUntil[plot] = nil
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		promptLimiter:remove(player)
		thiefCooldownUntil[player] = nil
		local plot = hackingPlotOf[player]
		if plot then
			cancelHack(plot, "вор покинул игру", false)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(HACK_TICK)
			xpcall(updateHacks, function(message: any)
				warn(`[CashRegister] Ошибка обновления взломов: {message}\n{debug.traceback()}`)
			end)
		end
	end)
end

return CashRegisterService
