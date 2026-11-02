--!strict
--[[
	CombatService — последствия боя: выпадение денег и штраф за выход из боя.

	• Урон запоминается: кто и когда ранил игрока (recordDamage вызывают
	  WeaponService — урон от игроков — и GuardAIService — урон от охраны).
	• Игрок погиб, и в последние KILL_CREDIT_WINDOW секунд его ранили игрок или
	  охрана → из кошелька выпадает DROP_FRACTION денег пачкой на месте гибели.
	  Подобрать её может кто угодно (подсказка «Подобрать»), через DROP_LIFETIME
	  секунд пачка исчезает. Смерть без нападавшего (упал с высоты) — без потерь.
	• Выход из игры в бою (ранен меньше COMBAT_LOG_WINDOW секунд назад) — тот же
	  штраф: деньги остаются лежать там, где игрока видели последний раз.
	  Иначе владелец выходил бы из игры, чтобы не отдавать деньги нападающим.

	Деньги не создаются из воздуха: пачка — это часть кошелька погибшего,
	поэтому «фарм» убийствами со своего второго аккаунта ничего не даёт.

	ЗАЩИТА:
	• Сумма пачки хранится на сервере, атрибут Amount — только витрина.
	• Расстояние до пачки проверяет сервер (fireproximityprompt издалека не пройдёт).
	• Пачку забирает первый: снятие и зачисление без yield между ними.
	• Кто нанёс урон, знает только сервер.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local RateLimiter = require(script.Parent.Parent.Modules.RateLimiter)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)

local DROP_FRACTION = 0.2 -- доля кошелька, которая выпадает при гибели в бою
local MIN_DROP = 10 -- меньше — не выпадает
local KILL_CREDIT_WINDOW = 10 -- секунд: урон раньше этого не считается причиной смерти
local COMBAT_LOG_WINDOW = 15 -- секунд после урона игрок считается «в бою»
local DROP_LIFETIME = 90 -- секунд до исчезновения пачки
local PICKUP_DISTANCE = 12 -- серверный предел (с запасом на пинг)
local PROMPT_DISTANCE = 8
local DROPS_FOLDER = "CashDrops"
local DROP_TAG = "CashDrop"

type DamageRecord = { attacker: Player?, time: number, position: Vector3 }
type Drop = { amount: number, part: BasePart }

local CombatService = {}

local lastDamage: { [Player]: DamageRecord } = {}
local reductions: { [Player]: { fraction: number, untilTime: number } } = {}
local drops: { [BasePart]: Drop } = {}
local pickupLimiter = RateLimiter.new(3, 5)
local dropsFolder: Folder? = nil

--------------------------------------------------------------------------------
-- Пачки денег
--------------------------------------------------------------------------------

local function onPickup(part: BasePart, player: Player)
	if not pickupLimiter:check(player) then
		NetService:flag(player, "слишком частый подбор денег", NetService.Penalty.RateLimit)
		return
	end
	local drop = drops[part]
	local _, _, root = CharacterUtil.getAlive(player)
	if drop == nil or root == nil or not DataService:isLoaded(player) then
		return
	end
	if (root.Position - part.Position).Magnitude > PICKUP_DISTANCE then
		NetService:flag(player, "подбор денег издалека", NetService.Penalty.BadRequest)
		return
	end
	-- Снятие и зачисление без yield: вторая попытка увидит, что пачки уже нет.
	drops[part] = nil
	part:Destroy()
	DataService:increment(player, "Cash", drop.amount)
	NetService:notify(player, `Подобрано: +${drop.amount}`)
end

-- Положить пачку денег в точку position. Возвращает деталь или nil (сумма меньше 1).
-- Используется при гибели, выходе из боя, разбитой кассе.
function CombatService:spawnDrop(position: Vector3, amount: number): BasePart?
	local value = math.floor(amount)
	if value < 1 or dropsFolder == nil then
		return nil
	end
	local part = Instance.new("Part")
	part.Name = "CashDrop"
	part.Size = Vector3.new(1.6, 0.8, 1.2)
	part.Color = Color3.fromRGB(80, 200, 90)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- не загораживает обзор охране и не ловит пули
	part.CanTouch = false
	part.CFrame = CFrame.new(position)
	part:SetAttribute("Amount", value)
	CollectionService:AddTag(part, DROP_TAG)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = `Подобрать ${value}`
	prompt.ObjectText = "Деньги"
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player: Player)
		onPickup(part, player)
	end)

	local drop: Drop = { amount = value, part = part }
	drops[part] = drop
	part.Parent = dropsFolder
	task.delay(DROP_LIFETIME, function()
		if drops[part] == drop then
			drops[part] = nil
			part:Destroy()
		end
	end)
	return part
end

-- Отнять долю кошелька и положить её пачкой. Возвращает сумму.
local function dropWallet(player: Player, position: Vector3): number
	local data = DataService:get(player)
	if data == nil then
		return 0
	end
	local amount = math.floor(data.Cash * DROP_FRACTION)
	if amount < MIN_DROP then
		return 0
	end
	DataService:increment(player, "Cash", -amount)
	CombatService:spawnDrop(position, amount)
	return amount
end

--------------------------------------------------------------------------------
-- Урон, гибель, выход из боя
--------------------------------------------------------------------------------

-- Запомнить, что игрока ранили. attacker = nil — урон от охраны ресторана.
-- Вызывать ДО нанесения урона: смертельный урон сразу вызывает Died.
function CombatService:recordDamage(victim: Player, attacker: Player?)
	local _, _, root = CharacterUtil.getAlive(victim)
	local previous = lastDamage[victim]
	local position = if root then root.Position elseif previous then previous.position else Vector3.new()
	lastDamage[victim] = { attacker = attacker, time = os.clock(), position = position }
end

-- Снизить входящий урон по игроку на долю fraction на duration секунд (щит Танка).
function CombatService:addDamageReduction(player: Player, fraction: number, duration: number)
	reductions[player] = { fraction = math.clamp(fraction, 0, 0.95), untilTime = os.clock() + duration }
end

-- Единственная точка урона по игроку: учитывает снижение урона и запоминает нападавшего.
-- attacker = nil — урон от охраны. Возвращает нанесённый урон.
function CombatService:damagePlayer(victim: Player, amount: number, attacker: Player?): number
	local _, humanoid = CharacterUtil.getAlive(victim)
	if humanoid == nil or amount <= 0 then
		return 0
	end
	local reduction = reductions[victim]
	local factor = if reduction and reduction.untilTime > os.clock() then 1 - reduction.fraction else 1
	local dealt = amount * factor
	CombatService:recordDamage(victim, attacker) -- до урона: смертельный урон сразу вызывает Died
	humanoid:TakeDamage(dealt)
	return dealt
end

function CombatService:isInCombat(player: Player): boolean
	local record = lastDamage[player]
	return record ~= nil and os.clock() - record.time < COMBAT_LOG_WINDOW
end

local function onDeath(player: Player, character: Model)
	local record = lastDamage[player]
	lastDamage[player] = nil
	if record == nil or os.clock() - record.time > KILL_CREDIT_WINDOW then
		return -- погиб сам (падение и т. п.) — без потерь
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local position = if root and root:IsA("BasePart") then (root :: BasePart).Position else record.position
	local lost = dropWallet(player, position - Vector3.new(0, 2, 0))
	if lost > 0 then
		NetService:notify(player, `Вы погибли и выронили ${lost}`)
	end
	local attacker = record.attacker
	if attacker and attacker.Parent == Players then
		NetService:notify(attacker, `Вы победили {player.DisplayName}`)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		local typed = humanoid :: Humanoid
		typed.Died:Connect(function()
			onDeath(player, character)
		end)
	end
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function CombatService:Init()
	local folder = Instance.new("Folder")
	folder.Name = DROPS_FOLDER
	folder.Parent = workspace
	dropsFolder = folder
end

function CombatService:Start()
	DataService:onLoaded(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		local character = player.Character
		if character then
			task.spawn(onCharacterAdded, player, character)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		pickupLimiter:remove(player)
		reductions[player] = nil
		local record = lastDamage[player]
		lastDamage[player] = nil
		-- Данные ещё доступны: DataService сохраняет их после всех обработчиков выхода.
		if record and os.clock() - record.time < COMBAT_LOG_WINDOW then
			local lost = dropWallet(player, record.position - Vector3.new(0, 2, 0))
			warn(`[Combat] {player.Name} вышел из игры в бою и выронил ${lost}`)
		end
	end)
end

return CombatService
