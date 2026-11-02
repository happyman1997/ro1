--!strict
--[[
	NetService — сетевой слой сервера.

	• Создаёт RemoteEvent-ы из реестра Shared/Remotes в ReplicatedStorage.Remotes.
	• Принимает запросы клиентов ТОЛЬКО через NetService:on(). Каждый запрос
	  проходит ограничение частоты (RateLimiter) и проверку аргументов (Guard).
	• Ведёт «счёт подозрительности» игроков и кикает явных читеров.

	Первый аргумент обработчика (player) подставляет сам Roblox — подделать его
	нельзя. Всё остальное присылает клиент, и этому верить нельзя.

	Обработчик вызывается, только если все проверки пройдены, поэтому внутри
	можно доверять ТИПАМ аргументов, но не их смыслу: запрос «купить предмет X»
	всё равно требует проверки цены, денег, расстояния до магазина и т. д.

	Пример:
		NetService:on("BuyItem", {
			args = { Guard.keyOf(ShopItems), Guard.integer(1, 99) },
			rate = 2, burst = 5,
		}, function(player, itemId: string, amount: number)
			...
		end)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Guard = require(ReplicatedStorage.Shared.Guard)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RateLimiter = require(script.Parent.Parent.Modules.RateLimiter)

-- Очки подозрительности: начисляются за нарушения и со временем «остывают».
-- За превышение частоты очков мало: его может вызвать и честный лаг (пачка
-- накопившихся пакетов приходит разом). Неверные аргументы честный клиент
-- не пришлёт никогда, за них очков много.
local SUSPICION_DECAY_PER_SECOND = 0.5
local SUSPICION_KICK_THRESHOLD = 50
local LOG_COOLDOWN = 1 -- не чаще одной записи в лог в секунду на игрока

local DEFAULT_RATE = 10 -- запросов в секунду, если в on() не указано

export type Handler = (player: Player, ...any) -> ()
export type HandlerOptions = {
	args: { Guard.Check }, -- проверка для каждого аргумента по порядку
	rate: number?, -- запросов в секунду в среднем (по умолчанию 10)
	burst: number?, -- сколько запросов можно подряд (по умолчанию = rate)
}

type Suspicion = { score: number, updatedAt: number, loggedAt: number }

local NetService = {}

-- Штрафы для NetService:flag(). Используйте их и в своих сервисах.
NetService.Penalty = table.freeze({
	RateLimit = 1,
	BadRequest = 10,
})

local remotes: { [string]: RemoteEvent } = {}
local boundNames: { [string]: boolean } = {}
local limiters: { RateLimiter.RateLimiter } = {}
local suspicion: { [Player]: Suspicion } = {}

local function getInfo(name: string): Remotes.RemoteInfo
	local info = Remotes[name]
	assert(info, `NetService: событие «{name}» не объявлено в Shared/Remotes`)
	return info
end

function NetService:Init()
	-- Источник правды — реестр Remotes. Папку, созданную вручную в Studio, заменяем.
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing then
		warn("[NetService] В ReplicatedStorage уже была папка Remotes — она заменена")
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Remotes"

	for name, info in Remotes do
		local instance: Instance = if info.kind == "Unreliable"
			then Instance.new("UnreliableRemoteEvent")
			else Instance.new("RemoteEvent")
		instance.Name = name
		instance.Parent = folder

		-- У UnreliableRemoteEvent те же методы, поэтому храним оба вида под одним типом.
		local remote = (instance :: any) :: RemoteEvent
		remotes[name] = remote

		if info.direction == "ToClient" then
			-- Честный клиент сюда никогда не отправляет. «Ловушка» заодно не даёт
			-- событиям копиться в очереди сервера (без обработчика они бы копились).
			remote.OnServerEvent:Connect(function(player: Player)
				NetService:flag(
					player,
					`отправка в серверное событие «{name}»`,
					NetService.Penalty.BadRequest
				)
			end)
		end
	end

	-- Родителя назначаем последним: клиент увидит папку сразу со всеми событиями.
	folder.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player: Player)
		suspicion[player] = nil
		for _, limiter in limiters do
			limiter:remove(player)
		end
	end)
end

-- Подписаться на запросы клиентов (только для событий "ToServer").
-- Вызывайте из Start() своего сервиса. Одно событие — один обработчик.
function NetService:on(name: string, options: HandlerOptions, handler: Handler)
	local info = getInfo(name)
	assert(info.direction == "ToServer", `NetService:on: «{name}» — событие сервер → клиент`)
	assert(not boundNames[name], `NetService:on: у «{name}» уже есть обработчик`)
	assert(remotes[name], "NetService:on вызван до NetService:Init (подписывайтесь в Start)")
	boundNames[name] = true

	local rate = options.rate or DEFAULT_RATE
	local limiter = RateLimiter.new(rate, options.burst or rate)
	table.insert(limiters, limiter)
	local checks = options.args

	remotes[name].OnServerEvent:Connect(function(player: Player, ...: any)
		if not limiter:check(player) then
			NetService:flag(
				player,
				`слишком частые запросы «{name}»`,
				NetService.Penalty.RateLimit
			)
			return
		end

		local ok, badIndex = Guard.args(checks, ...)
		if not ok then
			local detail = if badIndex then `аргумент №{badIndex}` else "лишние аргументы"
			NetService:flag(player, `неверный запрос «{name}»: {detail}`, NetService.Penalty.BadRequest)
			return
		end

		handler(player, ...)
	end)
end

-- Отправить событие одному игроку.
function NetService:fireClient(player: Player, name: string, ...: any)
	assert(
		getInfo(name).direction == "ToClient",
		`NetService: «{name}» — событие клиент → сервер`
	)
	remotes[name]:FireClient(player, ...)
end

-- Отправить событие всем игрокам.
function NetService:fireAllClients(name: string, ...: any)
	assert(
		getInfo(name).direction == "ToClient",
		`NetService: «{name}» — событие клиент → сервер`
	)
	remotes[name]:FireAllClients(...)
end

-- Отправить событие игрокам, чьи персонажи ближе radius к точке (эффекты выстрелов и т. п.).
-- except — игрок, которому не отправлять (например, стрелок сам рисует свой трассер).
function NetService:fireNearby(position: Vector3, radius: number, except: Player?, name: string, ...: any)
	assert(
		getInfo(name).direction == "ToClient",
		`NetService: «{name}» — событие клиент → сервер`
	)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			local character = player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if root and root:IsA("BasePart") and ((root :: BasePart).Position - position).Magnitude <= radius then
				remotes[name]:FireClient(player, ...)
			end
		end
	end
end

-- Показать игроку текстовое уведомление (обрабатывает NotificationController).
function NetService:notify(player: Player, text: string)
	if player.Parent == Players then
		remotes.Notify:FireClient(player, text)
	end
end

-- Засчитать игроку подозрительное действие. При превышении порога — кик.
-- Используйте и в своих сервисах: например, если игрок «купил» товар
-- из магазина, до которого 500 студов.
function NetService:flag(player: Player, reason: string, penalty: number)
	local now = os.clock()
	local entry = suspicion[player]
	if entry == nil then
		entry = { score = 0, updatedAt = now, loggedAt = -math.huge }
		suspicion[player] = entry
	end

	entry.score = math.max(0, entry.score - (now - entry.updatedAt) * SUSPICION_DECAY_PER_SECOND) + penalty
	entry.updatedAt = now

	if now - entry.loggedAt >= LOG_COOLDOWN then
		entry.loggedAt = now
		warn(`[Анти-чит] {player.Name} ({player.UserId}): {reason}. Очки: {math.floor(entry.score)}`)
	end

	if entry.score >= SUSPICION_KICK_THRESHOLD then
		suspicion[player] = nil
		warn(
			`[Анти-чит] {player.Name} ({player.UserId}) кикнут: превышен порог подозрительности`
		)
		player:Kick(
			"Обнаружена подозрительная активность. Если это ошибка, просто перезайдите."
		)
	end
end

return NetService
