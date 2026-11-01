--!strict
--[[
	GuardAIService — обнаружение и атака нарушителей охраной и турелями.

	Защитник — модель на участке с тегом "Guard" (с Humanoid) или "Turret"
	и атрибутом DefenderType (ключ из Config/Defense). Неважно, кто его поставил:
	шаблон уровня, будущий DefenseService (наём) или дизайнер вручную.

	Цикл раз в SCAN_INTERVAL секунд (один на всех, а не поток на каждого):
	  1. Кандидаты участка: чужие живые игроки на территории, а также игроки
	     из «памяти тревоги» этого участка (даже за территорией — например,
	     стреляющие с улицы).
	  2. Для каждого защитника выбирается цель:
	     • подходит по правилу Detection (см. ниже);
	     • в радиусе Range;
	     • в секторе FieldOfView. Если тревога по этому игроку уже поднята,
	       сектор не нужен: охрана «знает» о нём и разворачивается;
	     • видна (луч не упирается в глухую преграду, см. LineOfSight).
	     Из подходящих берётся с наименьшим «расстояние / Threat»: Танк с
	     Threat = 3 притягивает огонь на себя.
	  3. Цель видна → тревога на весь участок (память ALARM_MEMORY секунд,
	     обновляется, пока цель видна), бой отмечается в PlotService.
	     Дальний бой: выстрел, если есть линия огня (бронестекло видно, но не
	     простреливается). Ближний: удар в упор или погоня в пределах поводка.

	Правила обнаружения (Detection):
	  "Armed"    (люди-охранники): чужой игрок с оружием в руках, ИЛИ разведчик
	             без маскировки (взламывает кассу или раскрыт).
	  "Intruder" (турели): любой чужой игрок, КРОМЕ разведчика в маскировке.
	  Обоим: любой игрок из памяти тревоги (засветился или напал —
	  GuardAIService:reportAggression).

	ЗАЩИТА:
	• Оружие в руках проверяется по данным сервера (CharacterUtil). Стрелять
	  можно только экипированным на сервере оружием — это контракт WeaponService.
	  Поэтому «спрятать оружие» и «стрелять» одновременно нельзя.
	• Память тревоги не даёт обмануть охрану трюком «достал, выстрелил, убрал».
	• Лучи видимости и урон — только на сервере; локальное удаление стен
	  на клиенте ничего не даёт.
	• Физика охранников принадлежит серверу (NpcUtil): клиент не может утащить
	  или сбросить охранника.
	• Позицию персонажа присылает клиент. От телепорта к кассе мимо охраны
	  защищает отдельная проверка перемещения (MovementService, в планах).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Defense = require(ReplicatedStorage.Shared.Config.Defense)
local LineOfSight = require(script.Parent.Parent.Modules.LineOfSight)
local NpcUtil = require(script.Parent.Parent.Modules.NpcUtil)
local ClassService = require(script.Parent.ClassService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local GUARD_TAG = "Guard"
local TURRET_TAG = "Turret"

local SCAN_INTERVAL = 0.2 -- секунд между проходами ИИ
local ALARM_MEMORY = 12 -- сколько секунд охрана помнит нарушителя после последнего контакта
local OWNER_ALERT_COOLDOWN = 15 -- не чаще одного уведомления владельцу
local MELEE_REACH = 6 -- дистанция удара вышибалы
local MISS_SPREAD = 3 -- разброс трассера при промахе, студы
local EFFECT_RADIUS = 250 -- кому отправлять эффект выстрела

type Plot = PlotService.Plot

type Defender = {
	model: Model,
	info: Defense.DefenderInfo,
	plot: Plot,
	humanoid: Humanoid?, -- у охранников
	root: BasePart?, -- HumanoidRootPart охранника
	eye: BasePart, -- откуда смотрит (Head или PrimaryPart)
	turretHead: BasePart?, -- поворотная голова турели (заякоренная)
	muzzle: Attachment?, -- откуда летят пули
	post: Vector3, -- пост, куда возвращается вышибала
	nextAttackAt: number,
}

type Candidate = {
	player: Player,
	character: Model,
	root: BasePart,
	humanoid: Humanoid,
	alarmed: boolean, -- уже в памяти тревоги участка
	matchesArmed: boolean, -- цель для правила "Armed"
	matchesIntruder: boolean, -- цель для правила "Intruder"
	threat: number,
}

local GuardAIService = {}

local defenders: { [Model]: Defender } = {}
local hostileUntil: { [Plot]: { [Player]: number } } = {}
local lastOwnerAlert: { [Plot]: number } = {}
local random = Random.new()

--------------------------------------------------------------------------------
-- Регистрация защитников
--------------------------------------------------------------------------------

local function onDefenderAdded(instance: Instance)
	-- Шаблоны в ServerStorage тоже «добавляются» в DataModel — их пропускаем.
	if not instance:IsA("Model") or not instance:IsDescendantOf(workspace) then
		return
	end
	local model = instance :: Model
	if defenders[model] then
		return
	end

	local typeId = model:GetAttribute("DefenderType")
	local info = if typeof(typeId) == "string" then Defense[typeId] else nil
	if info == nil then
		warn(`[GuardAI] {model:GetFullName()}: неизвестный DefenderType «{tostring(typeId)}»`)
		return
	end
	local plot = PlotService:getPlotFromInstance(model)
	if plot == nil then
		warn(
			`[GuardAI] {model:GetFullName()}: защитник должен стоять внутри модели участка`
		)
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootInstance = model:FindFirstChild("HumanoidRootPart")
	local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance :: BasePart else nil
	local headInstance = model:FindFirstChild("Head")
	local head = if headInstance and headInstance:IsA("BasePart") then headInstance :: BasePart else nil
	local eye = head or root or model.PrimaryPart
	if eye == nil then
		warn(`[GuardAI] {model:GetFullName()}: нужна деталь Head, HumanoidRootPart или PrimaryPart`)
		return
	end
	local muzzleInstance = model:FindFirstChild("Muzzle", true)
	local muzzle = if muzzleInstance and muzzleInstance:IsA("Attachment") then muzzleInstance :: Attachment else nil

	if info.Kind == "Turret" and model:GetAttribute("Health") == nil then
		model:SetAttribute("Health", info.MaxHealth)
	end
	NpcUtil.claimNetworkOwnership(model)

	defenders[model] = {
		model = model,
		info = info,
		plot = plot,
		humanoid = humanoid,
		root = root,
		eye = eye,
		turretHead = if info.Kind == "Turret" and head and head.Anchored then head else nil,
		muzzle = muzzle,
		post = (root or eye).Position,
		nextAttackAt = 0,
	}
end

local function onDefenderRemoved(instance: Instance)
	defenders[instance :: Model] = nil
end

local function isAlive(defender: Defender): boolean
	if not defender.model:IsDescendantOf(workspace) then
		return false
	end
	local humanoid = defender.humanoid
	if humanoid then
		return humanoid.Health > 0
	end
	local health = defender.model:GetAttribute("Health")
	return typeof(health) ~= "number" or health > 0
end

--------------------------------------------------------------------------------
-- Тревога
--------------------------------------------------------------------------------

local function isAlarmed(plot: Plot, player: Player, now: number): boolean
	local memory = hostileUntil[plot]
	return memory ~= nil and (memory[player] or 0) > now
end

local function raiseAlarm(plot: Plot, player: Player, now: number)
	local memory = hostileUntil[plot]
	if memory == nil then
		memory = {}
		hostileUntil[plot] = memory
	end
	memory[player] = now + ALARM_MEMORY
	PlotService:markCombat(plot)

	local owner = plot.owner
	if owner and now - (lastOwnerAlert[plot] or -math.huge) >= OWNER_ALERT_COOLDOWN then
		lastOwnerAlert[plot] = now
		NetService:notify(
			owner,
			`Тревога! Охрана атакует нарушителя: {player.DisplayName}`
		)
	end
end

--------------------------------------------------------------------------------
-- Восприятие
--------------------------------------------------------------------------------

-- Все потенциальные цели участка с заранее вычисленными признаками
-- (один раз на участок за проход, а не на каждого защитника).
local function collectCandidates(plot: Plot, now: number): { Candidate }
	local candidates: { Candidate } = {}
	for _, player in Players:GetPlayers() do
		if PlotService:isFriendly(plot, player) then
			continue
		end
		local character, humanoid, root = CharacterUtil.getAlive(player)
		if character == nil or humanoid == nil or root == nil then
			continue
		end
		local alarmed = isAlarmed(plot, player, now)
		if not alarmed and not PlotService:isInTerritory(plot, root.Position) then
			continue
		end

		local class = ClassService:getClass(player)
		local disguised = ClassService:isDisguised(player)
		local armed = CharacterUtil.getEquippedWeapon(character) ~= nil
		-- Разведчик без маскировки = взламывает кассу или раскрыт.
		local blownCover = class.Disguise and not disguised

		local candidate: Candidate = {
			player = player,
			character = character,
			root = root,
			humanoid = humanoid,
			alarmed = alarmed,
			matchesArmed = alarmed or armed or blownCover,
			matchesIntruder = alarmed or not disguised,
			threat = math.max(class.Threat, 0.1),
		}
		table.insert(candidates, candidate)
	end
	return candidates
end

local function ignoreListFor(defender: Defender): { Instance }
	-- Свои защитники не загораживают друг другу обзор.
	return { defender.model, defender.plot.defenseFolder }
end

local function findTarget(defender: Defender, candidates: { Candidate }): Candidate?
	local info = defender.info
	local eyePosition = defender.eye.Position
	local forward = defender.eye.CFrame.LookVector
	local halfFov = math.rad(info.FieldOfView / 2)
	local ignore = ignoreListFor(defender)

	local best: Candidate? = nil
	local bestScore = math.huge
	for _, candidate in candidates do
		local matches = if info.Detection == "Intruder" then candidate.matchesIntruder else candidate.matchesArmed
		if not matches then
			continue
		end
		local offset = candidate.root.Position - eyePosition
		local distance = offset.Magnitude
		if distance > info.Range or distance < 0.01 then
			continue
		end
		if not candidate.alarmed and info.FieldOfView < 360 then
			local angle = math.acos(math.clamp(forward:Dot(offset / distance), -1, 1))
			if angle > halfFov then
				continue
			end
		end
		local score = distance / candidate.threat
		-- Луч — самая дорогая проверка, поэтому делаем её последней.
		if score < bestScore and LineOfSight.canSee(eyePosition, candidate.character, ignore) then
			best = candidate
			bestScore = score
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Действия
--------------------------------------------------------------------------------

local function broadcastShot(origin: Vector3, impact: Vector3)
	for _, player in Players:GetPlayers() do
		local _, _, root = CharacterUtil.getAlive(player)
		if root and (root.Position - origin).Magnitude <= EFFECT_RADIUS then
			NetService:fireClient(player, "DefenderFired", origin, impact)
		end
	end
end

local function faceTarget(defender: Defender, position: Vector3)
	local turretHead = defender.turretHead
	if turretHead then
		turretHead.CFrame = CFrame.lookAt(turretHead.Position, position)
		return
	end
	-- Стационарный охранник с заякоренным корнем поворачивается только по горизонтали.
	local root = defender.root
	if root and root.Anchored and not defender.info.Melee then
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(position.X, root.Position.Y, position.Z))
	end
end

local function meleeAttack(defender: Defender, target: Candidate, now: number)
	local humanoid = defender.humanoid
	local root = defender.root
	if humanoid == nil or root == nil then
		return
	end
	local targetPosition = target.root.Position
	if (targetPosition - root.Position).Magnitude <= MELEE_REACH then
		if now >= defender.nextAttackAt then
			defender.nextAttackAt = now + defender.info.FireInterval
			target.humanoid:TakeDamage(defender.info.Damage)
		end
	elseif (targetPosition - defender.post).Magnitude <= defender.info.LeashRadius then
		humanoid:MoveTo(targetPosition)
	else
		humanoid:MoveTo(defender.post) -- цель за поводком: возвращаемся охранять
	end
end

local function rangedAttack(defender: Defender, target: Candidate, now: number)
	if now < defender.nextAttackAt then
		return
	end
	local origin = if defender.muzzle then defender.muzzle.WorldPosition else defender.eye.Position
	local clear, impact = LineOfSight.canShoot(origin, target.character, ignoreListFor(defender))
	if not clear then
		return -- видит, но не простреливает: ждёт, пока цель выйдет из-за укрытия
	end
	defender.nextAttackAt = now + defender.info.FireInterval

	if random:NextNumber() <= defender.info.Accuracy then
		target.humanoid:TakeDamage(defender.info.Damage)
	else
		impact += random:NextUnitVector() * MISS_SPREAD
	end
	broadcastShot(origin, impact)
end

local function engage(defender: Defender, target: Candidate, now: number)
	raiseAlarm(defender.plot, target.player, now)
	faceTarget(defender, target.root.Position)
	if defender.info.Melee then
		meleeAttack(defender, target, now)
	else
		rangedAttack(defender, target, now)
	end
end

local function idle(defender: Defender)
	local humanoid = defender.humanoid
	local root = defender.root
	if defender.info.Melee and humanoid and root and (root.Position - defender.post).Magnitude > 2 then
		humanoid:MoveTo(defender.post)
	end
end

--------------------------------------------------------------------------------
-- Основной цикл
--------------------------------------------------------------------------------

local function scan()
	local now = os.clock()

	-- Группируем живых защитников по участкам с владельцем.
	local byPlot: { [Plot]: { Defender } } = {}
	for _, defender in defenders do
		if defender.plot.owner ~= nil and isAlive(defender) then
			local list = byPlot[defender.plot]
			if list == nil then
				list = {}
				byPlot[defender.plot] = list
			end
			table.insert(list, defender)
		end
	end

	for plot, list in byPlot do
		local candidates = collectCandidates(plot, now)
		for _, defender in list do
			local target = if #candidates > 0 then findTarget(defender, candidates) else nil
			if target then
				engage(defender, target, now)
			else
				idle(defender)
			end
		end
	end

	-- Забываем нарушителей, по которым память истекла.
	for plot, memory in hostileUntil do
		for player, untilTime in memory do
			if untilTime <= now then
				memory[player] = nil
			end
		end
		if next(memory) == nil then
			hostileUntil[plot] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Игрок напал на ресторан: ранил персонал, охрану или владельца, сломал мебель
-- или стену. Вызывает боевая система (CombatService). Охрана участка будет
-- атаковать его ALARM_MEMORY секунд независимо от оружия и маскировки.
function GuardAIService:reportAggression(plot: Plot, player: Player)
	if plot.owner ~= nil and not PlotService:isFriendly(plot, player) then
		raiseAlarm(plot, player, os.clock())
	end
end

function GuardAIService:isHostile(plot: Plot, player: Player): boolean
	return isAlarmed(plot, player, os.clock())
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function GuardAIService:Start()
	for _, tag in { GUARD_TAG, TURRET_TAG } do
		CollectionService:GetInstanceAddedSignal(tag):Connect(onDefenderAdded)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(onDefenderRemoved)
		for _, instance in CollectionService:GetTagged(tag) do
			onDefenderAdded(instance)
		end
	end

	PlotService.PlotReleased:Connect(function(_, plot: Plot)
		hostileUntil[plot] = nil
		lastOwnerAlert[plot] = nil
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		for _, memory in hostileUntil do
			memory[player] = nil
		end
	end)

	task.spawn(function()
		while true do
			task.wait(SCAN_INTERVAL)
			-- Ошибка в одном проходе не должна навсегда выключить охрану сервера.
			xpcall(scan, function(message: any)
				warn(`[GuardAI] Ошибка прохода: {message}\n{debug.traceback()}`)
			end)
		end
	end)
end

return GuardAIService
