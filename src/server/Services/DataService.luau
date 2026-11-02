--!strict
--[[
	DataService — загрузка, хранение и сохранение данных игроков.

	Гарантии:
	• Блокировка сессии. Пока игрок на сервере А, его запись в DataStore помечена
	  «занято сервером А». Если игрок быстро перешёл на сервер Б, тот ждёт, пока
	  А сохранит данные и снимет метку. Без этого возможны дюп предметов и откат
	  прогресса: Б загрузил бы старые данные раньше, чем А сохранил новые.
	  Если метка не снимается (сервер А упал), Б забирает её после ожидания,
	  а А, обнаружив это при следующем сохранении, перестаёт писать.
	• Если данные загрузить не удалось, игрок кикается. Нельзя пускать его
	  с данными «по умолчанию»: при выходе они перезапишут настоящий прогресс.
	• Данные меняются только через set / increment / update. Изменения сразу
	  проверяются (можно ли их сохранить), уходят клиенту и в сигнал Changed.
	• Автосохранение каждые AUTOSAVE_INTERVAL секунд и сохранение всех
	  при остановке сервера (BindToClose).

	В Studio без доступа к API (Game Settings → Security → Enable Studio Access
	to API Services) используется временное хранилище в памяти.

	Пример использования в другом сервисе:
		DataService:onLoaded(function(player, data) print(data.Cash) end)
		DataService:increment(player, "Cash", 10)
		DataService:update(player, "Settings", function(settings)
			settings.ShowTips = false
			return settings
		end)
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataTemplate = require(ReplicatedStorage.Shared.DataTemplate)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Migrations = require(script.Parent.Parent.Modules.Migrations)
local NetService = require(script.Parent.NetService)

-- Смена имени хранилища = все игроки начинают с нуля. Меняйте только осознанно.
local STORE_NAME = "PlayerData_v1"
local KEY_PREFIX = "Player_"

local AUTOSAVE_INTERVAL = 60 -- секунд между автосохранениями
-- Метка, которую не обновляли дольше этого срока, считается брошенной
-- (живой сервер обновляет её при каждом автосохранении).
local LOCK_TIMEOUT = AUTOSAVE_INTERVAL * 3
local LOAD_ATTEMPTS = 6 -- попыток загрузки; на последней чужая метка забирается силой
local LOAD_RETRY_DELAY = 5
local SAVE_ATTEMPTS = 3
local SHUTDOWN_TIMEOUT = 25 -- Roblox даёт BindToClose максимум 30 секунд

-- Уникальный id этого сервера для меток. Не game.JobId: в Studio он пустой.
local SERVER_ID = HttpService:GenerateGUID(false)

type PlayerData = DataTemplate.PlayerData

type Lock = { ServerId: string, Time: number }

-- Формат записи в DataStore.
type Record = { Data: any, Lock: Lock? }

type Session = {
	data: PlayerData,
	key: string,
	saving: boolean, -- идёт запись в DataStore
	released: boolean, -- сессия закрыта, больше не пишем
}

type Transform = (old: any) -> (any, { number }?)
-- Возвращает новое значение записи (результат нам не нужен, но с ним pcall типизируется проще).
type UpdateAsync = (key: string, transform: Transform) -> any

type AcquireProblem = "left" | "corrupt" | "error"
type WriteResult = "ok" | "lost" | "error"

local DataService = {}

-- (player, data) — данные игрока загружены и готовы.
DataService.Loaded = Signal.new() :: Signal.Signal<Player, PlayerData>
-- (player, key, value) — поле данных изменилось.
DataService.Changed = Signal.new() :: Signal.Signal<Player, string, any>
-- (player, data) — игрок уходит; последний момент, чтобы СИНХРОННО (без yield)
-- записать итоговые значения (например, время в игре).
DataService.Releasing = Signal.new() :: Signal.Signal<Player, PlayerData>

local sessions: { [Player]: Session } = {}
local releasingUserIds: { [number]: boolean } = {} -- идёт финальное сохранение
local pendingOperations = 0 -- активные загрузки и финальные сохранения
local isShuttingDown = false

-- Задаётся в Init: настоящий DataStore или временное хранилище в памяти.
local updateAsync: UpdateAsync = function()
	error("DataService не инициализирован")
end

--------------------------------------------------------------------------------
-- Вспомогательные функции
--------------------------------------------------------------------------------

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[deepCopy(key)] = deepCopy(child)
	end
	return copy :: any
end

-- Дополнить target недостающими полями из template (рекурсивно).
-- Лишние поля не удаляем: их могла записать более новая версия игры.
-- Внутрь массивов не заходим: см. пояснение в DataTemplate.
local function reconcile(target: { [any]: any }, template: { [any]: any })
	for key, defaultValue in template do
		local current = target[key]
		if current == nil then
			target[key] = deepCopy(defaultValue)
		elseif type(current) == "table" and type(defaultValue) == "table" and #defaultValue == 0 then
			reconcile(current, defaultValue)
		end
	end
end

-- Можно ли сохранить значение в DataStore. Возвращает описание проблемы или nil.
-- Проверяем при каждом изменении: иначе ошибка всплыла бы только при сохранении,
-- и весь прогресс игрока за сессию был бы потерян.
local function findInvalid(value: any, path: string): string?
	local valueType = typeof(value)
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return `{path}: NaN или бесконечность`
		end
	elseif valueType == "string" then
		if utf8.len(value) == nil then
			return `{path}: строка с некорректным UTF-8`
		end
	elseif valueType == "table" then
		local hasStringKeys = false
		local numericCount = 0
		local maxIndex = 0
		for key, child in value do
			if type(key) == "string" then
				hasStringKeys = true
			elseif type(key) == "number" and key >= 1 and key % 1 == 0 then
				numericCount += 1
				maxIndex = math.max(maxIndex, key)
			else
				return `{path}: недопустимый ключ {tostring(key)}`
			end
			local problem = findInvalid(child, `{path}.{tostring(key)}`)
			if problem then
				return problem
			end
		end
		if hasStringKeys and numericCount > 0 then
			return `{path}: смешанная таблица (массив + словарь)`
		end
		if numericCount ~= maxIndex then
			return `{path}: массив с дырами`
		end
	elseif valueType ~= "boolean" then
		return `{path}: значение типа {valueType} нельзя сохранить`
	end
	return nil
end

-- Копия данных без приватных полей — для отправки клиенту.
local function publicSnapshot(data: PlayerData): { [string]: any }
	local snapshot = {}
	for key, value in data :: any do
		if not DataTemplate.PrivateKeys[key] then
			snapshot[key] = value
		end
	end
	return snapshot
end

-- Временное хранилище для Studio без доступа к API. Копирует значения,
-- как настоящий DataStore, чтобы поведение не отличалось.
local function createMemoryStore(): UpdateAsync
	local memory: { [string]: any } = {}
	return function(key: string, transform: Transform): any
		local newValue = transform(deepCopy(memory[key]))
		if newValue ~= nil then
			memory[key] = deepCopy(newValue)
		end
		return newValue
	end
end

--------------------------------------------------------------------------------
-- Работа с DataStore
--------------------------------------------------------------------------------

-- Захватить запись игрока: поставить метку «занято этим сервером».
local function acquire(player: Player, key: string): (Record?, AcquireProblem?)
	for attempt = 1, LOAD_ATTEMPTS do
		if player.Parent ~= Players then
			return nil, "left"
		end

		-- На последней попытке забираем метку, даже если она свежая: значит,
		-- прошлый сервер завис или упал, не успев её снять.
		local steal = attempt == LOAD_ATTEMPTS
		local acquired: Record? = nil
		local corrupt = false

		local ok, err = pcall(updateAsync, key, function(old: any): (Record?, { number }?)
			-- UpdateAsync может вызвать функцию несколько раз — сбрасываем флаги.
			acquired = nil
			corrupt = false

			if old ~= nil and type(old) ~= "table" then
				corrupt = true
				return nil, nil
			end

			local record = (old or {}) :: Record
			local lock = record.Lock
			local lockedByOther = type(lock) == "table"
				and lock.ServerId ~= SERVER_ID
				and type(lock.Time) == "number"
				and os.time() - lock.Time < LOCK_TIMEOUT
			if lockedByOther and not steal then
				return nil, nil -- отменяем запись и ждём, пока другой сервер снимет метку
			end

			record.Lock = { ServerId = SERVER_ID, Time = os.time() }
			acquired = record
			return record, { player.UserId }
		end)

		if ok and acquired then
			return acquired, nil
		elseif ok and corrupt then
			return nil, "corrupt"
		elseif not ok then
			warn(`[DataService] Ошибка загрузки {key} (попытка {attempt}/{LOAD_ATTEMPTS}): {err}`)
		end

		if attempt < LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_DELAY)
		end
	end
	return nil, "error"
end

-- Записать данные, если метка всё ещё наша. release = снять метку.
local function writeRecord(userId: number, key: string, data: any, release: boolean): WriteResult
	for attempt = 1, SAVE_ATTEMPTS do
		local lost = false

		local ok, err = pcall(updateAsync, key, function(old: any): (Record?, { number }?)
			lost = false
			local lock = if type(old) == "table" then old.Lock else nil
			if type(lock) ~= "table" or lock.ServerId ~= SERVER_ID then
				-- Запись захватил другой сервер — наши данные устарели, не пишем.
				lost = true
				return nil, nil
			end
			local record: Record = {
				Data = data,
				Lock = if release then nil else { ServerId = SERVER_ID, Time = os.time() },
			}
			return record, { userId }
		end)

		if ok then
			return if lost then "lost" else "ok"
		end
		warn(`[DataService] Ошибка сохранения {key} (попытка {attempt}/{SAVE_ATTEMPTS}): {err}`)
		if attempt < SAVE_ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
	return "error"
end

-- Подготовить загруженные данные: новый игрок, проверка версии, миграции, дополнение.
local function prepareData(record: Record): (PlayerData?, string?)
	local data = record.Data
	if data == nil then
		local fresh = deepCopy(DataTemplate.Template)
		fresh.Stats.FirstJoin = os.time()
		return fresh, nil
	end

	if type(data) ~= "table" or type(data.Version) ~= "number" then
		return nil, "corrupt"
	end
	if data.Version > DataTemplate.Version then
		-- Данные записаны более новой версией игры (этот сервер устарел).
		-- Старый код может их испортить, поэтому не загружаем.
		return nil, "newer"
	end

	while data.Version < DataTemplate.Version do
		local migrate = Migrations[data.Version]
		if migrate then
			migrate(data)
		end
		data.Version += 1
	end
	reconcile(data, DataTemplate.Template :: any)
	return data :: PlayerData, nil
end

local function saveSession(player: Player, session: Session, release: boolean)
	-- Автосохранение могло совпасть с выходом игрока — ждём окончания прошлой записи.
	while session.saving do
		task.wait()
	end
	if session.released then
		return
	end
	if release then
		session.released = true
	end

	session.saving = true
	local result = writeRecord(player.UserId, session.key, session.data, release)
	session.saving = false

	if result == "lost" then
		session.released = true
		if sessions[player] == session then
			sessions[player] = nil
		end
		warn(
			`[DataService] Данные {player.Name} захвачены другим сервером — сессия закрыта без сохранения`
		)
		if player.Parent == Players then
			player:Kick(
				"Ваши данные открыты на другом сервере. Перезайдите в игру."
			)
		end
	elseif result == "error" and release then
		warn(
			`[DataService] Не удалось сохранить {player.Name} при выходе: потерян прогресс с последнего автосохранения`
		)
	end
end

local function releasePlayer(player: Player)
	local session = sessions[player]
	if session == nil then
		return -- ещё загружается (loadPlayer разберётся сам) или уже закрыт
	end

	DataService.Releasing:Fire(player, session.data)
	sessions[player] = nil -- дальнейшие изменения не принимаются

	local userId = player.UserId
	releasingUserIds[userId] = true
	pendingOperations += 1
	xpcall(saveSession, function(message: any)
		warn(`[DataService] Ошибка при закрытии сессии {player.Name}: {message}`)
	end, player, session, true)
	pendingOperations -= 1
	releasingUserIds[userId] = nil
end

local function kickWithReason(player: Player, problem: string)
	if player.Parent ~= Players then
		return
	end
	local message = if problem == "newer"
		then "Этот сервер устарел. Перезайдите, чтобы попасть на обновлённый сервер."
		elseif
			problem == "corrupt"
		then "Ошибка в ваших сохранённых данных. Сообщите разработчику."
		else "Не удалось загрузить ваши данные. Пожалуйста, перезайдите через минуту."
	player:Kick(message)
end

local function loadPlayer(player: Player)
	local userId = player.UserId

	-- Игрок перезашёл на этот же сервер, пока шло финальное сохранение.
	-- Ждём его окончания, иначе загрузим устаревшие данные.
	while releasingUserIds[userId] do
		task.wait(0.5)
	end

	local key = KEY_PREFIX .. userId
	local record, acquireProblem = acquire(player, key)
	if record == nil then
		if acquireProblem ~= "left" then
			kickWithReason(player, acquireProblem or "error")
		end
		return
	end

	local data, dataProblem = prepareData(record)
	if data == nil then
		warn(`[DataService] {player.Name}: данные не загружены ({dataProblem})`)
		-- Снимаем метку, не меняя сохранённые данные.
		writeRecord(userId, key, record.Data, true)
		kickWithReason(player, dataProblem or "corrupt")
		return
	end

	data.Stats.Logins += 1
	data.Stats.LastJoin = os.time()

	local session: Session = { data = data, key = key, saving = false, released = false }
	sessions[player] = session

	if player.Parent ~= Players or isShuttingDown then
		-- Игрок ушёл (или сервер закрывается), пока шла загрузка.
		releasePlayer(player)
		return
	end

	NetService:fireClient(player, "DataSync", "Full", publicSnapshot(data))
	DataService.Loaded:Fire(player, data)
end

-- Запустить функцию, учитывая её в pendingOperations (BindToClose ждёт их завершения).
local function track(callback: (Player) -> (), player: Player)
	pendingOperations += 1
	xpcall(callback, function(message: any)
		warn(`[DataService] Ошибка для {player.Name}: {message}`)
	end, player)
	pendingOperations -= 1
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Данные игрока ТОЛЬКО ДЛЯ ЧТЕНИЯ. nil — не загружены или игрок ушёл.
-- Не меняйте таблицу напрямую: изменения не дойдут до клиента и не пройдут проверку.
function DataService:get(player: Player): PlayerData?
	local session = sessions[player]
	return if session then session.data else nil
end

function DataService:isLoaded(player: Player): boolean
	return sessions[player] ~= nil
end

-- Вызвать callback для каждого игрока с загруженными данными:
-- и для уже загруженных, и для будущих. Избавляет от гонки «подписался слишком поздно».
function DataService:onLoaded(callback: (Player, PlayerData) -> ()): Signal.Connection
	for player, session in table.clone(sessions) do
		task.spawn(callback, player, session.data)
	end
	return DataService.Loaded:Connect(callback)
end

-- Записать значение поля верхнего уровня.
function DataService:set(player: Player, key: string, value: any)
	local session = sessions[player]
	if session == nil then
		warn(
			`[DataService] set("{key}") для {player.Name}: данные не загружены, изменение отброшено`
		)
		return
	end
	if key == "Version" or (DataTemplate.Template :: any)[key] == nil then
		error(`[DataService] Поле «{key}» нельзя менять или его нет в DataTemplate`, 2)
	end
	local problem = findInvalid(value, key)
	if problem then
		error(`[DataService] Нельзя сохранить {problem}`, 2)
	end

	local data = session.data :: any
	data[key] = value

	DataService.Changed:Fire(player, key, value)
	if not DataTemplate.PrivateKeys[key] then
		NetService:fireClient(player, "DataSync", "Set", key, value)
	end
end

-- Прибавить delta к числовому полю. Возвращает новое значение (nil — данные не загружены).
function DataService:increment(player: Player, key: string, delta: number): number?
	local data = self:get(player) :: any
	if data == nil then
		warn(
			`[DataService] increment("{key}") для {player.Name}: данные не загружены, изменение отброшено`
		)
		return nil
	end
	local current = data[key]
	if type(current) ~= "number" then
		error(`[DataService] Поле «{key}» не числовое`, 2)
	end
	local newValue = current + delta
	self:set(player, key, newValue)
	return newValue
end

-- Изменить поле функцией (удобно для таблиц). transform получает текущее
-- значение и возвращает новое.
function DataService:update(player: Player, key: string, transform: (current: any) -> any)
	local data = self:get(player) :: any
	if data == nil then
		warn(
			`[DataService] update("{key}") для {player.Name}: данные не загружены, изменение отброшено`
		)
		return
	end
	self:set(player, key, transform(data[key]))
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

local function useMemoryStore(reason: string)
	warn(
		`[DataService] Сохранения работают в памяти ({reason}): прогресс пропадёт после остановки игры. `
			.. "Для настоящих сохранений опубликуйте место (File → Publish to Roblox) и включите "
			.. "Game Settings → Security → Enable Studio Access to API Services."
	)
	updateAsync = createMemoryStore()
end

function DataService:Init()
	-- PlaceId = 0 только у неопубликованного места (файл, открытый в Studio).
	-- DataStore там недоступен в принципе, поэтому даже не обращаемся к нему:
	-- иначе Roblox выводит ошибку «You must publish this place...».
	if game.PlaceId == 0 then
		useMemoryStore("место не опубликовано")
		return
	end

	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	local usable = ok
	if usable and RunService:IsStudio() then
		-- Опубликованное место в Studio: доступ к API может быть выключен в настройках.
		usable = pcall(function()
			local dataStore = store :: DataStore
			dataStore:GetAsync("__studio_probe")
		end)
	end

	if usable then
		local dataStore = store :: DataStore
		updateAsync = function(key: string, transform: Transform): any
			return dataStore:UpdateAsync(key, transform :: any)
		end
	elseif RunService:IsStudio() then
		useMemoryStore("в Studio выключен доступ к API")
	else
		-- Живой сервер без DataStore: игроки будут кикнуты с просьбой перезайти,
		-- но никто не начнёт с пустыми данными.
		warn(`[DataService] DataStore недоступен: {store}`)
		updateAsync = function()
			error("DataStore недоступен")
		end
	end
end

function DataService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		track(loadPlayer, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- defer: даём другим обработчикам PlayerRemoving этого кадра успеть записать данные.
		task.defer(releasePlayer, player)
	end)
	-- Игроки, которые успели зайти до запуска сервиса (частый случай в Studio).
	for _, player in Players:GetPlayers() do
		task.spawn(track, loadPlayer, player)
	end

	-- Автосохранение. Заодно обновляет метку, показывая, что сервер жив.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player, session in table.clone(sessions) do
				if sessions[player] == session then
					task.spawn(saveSession, player, session, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		isShuttingDown = true
		for player in table.clone(sessions) do
			task.spawn(releasePlayer, player)
		end
		local startedAt = os.clock()
		while (pendingOperations > 0 or next(sessions) ~= nil) and os.clock() - startedAt < SHUTDOWN_TIMEOUT do
			task.wait(0.1)
		end
	end)
end

return DataService
