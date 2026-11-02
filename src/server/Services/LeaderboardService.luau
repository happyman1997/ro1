--!strict
--[[
	LeaderboardService — глобальные рейтинги: самые богатые (Cash) и лучшие
	воры (Stats.CashStolen). Хранятся в OrderedDataStore, по одному на рейтинг.

	• Раз в UpdateInterval секунд сервер записывает значения своих игроков
	  (только изменившиеся) и читает топ (Config/Leaderboards).
	• При выходе игрока его значения записываются сразу.
	• Топ рассылается всем событием LeaderboardUpdate, новичку — при входе.
	• Без настоящего DataStore (Studio без публикации) рейтинги живут в памяти,
	  как и сохранения (DataService:isPersistent).

	ЗАЩИТА:
	• Клиент в рейтинги ничего не присылает: значения берутся только из
	  DataService на сервере.
	• Из Studio в настоящие рейтинги не пишем: там работают чат-команды (/cash),
	  и тест разработчика иначе попал бы в мировой топ. Studio их только читает.
	• В OrderedDataStore уходят только целые неотрицательные числа.
	• Запросов к DataStore мало: запись только изменившихся значений, чтение
	  топа раз в несколько минут, а не при каждом изменении денег.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataTemplate = require(ReplicatedStorage.Shared.DataTemplate)
local LeaderboardConfig = require(ReplicatedStorage.Shared.Config.Leaderboards)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)

type PlayerData = DataTemplate.PlayerData
type Entry = { userId: number, value: number }
export type Row = { userId: number, name: string, value: number }

type Store = {
	write: (userId: number, value: number) -> (),
	top: (count: number) -> { Entry }?,
}

local STORE_PREFIX = "Leaderboard_"
local STORE_VERSION = "_v1"
local MAX_VALUE = 2 ^ 53

-- Что считается в каждом рейтинге (ключи совпадают с Config/Leaderboards.Boards).
local VALUE_OF: { [string]: (data: PlayerData) -> number } = {
	Richest = function(data: PlayerData): number
		return data.Cash
	end,
	Thieves = function(data: PlayerData): number
		return data.Stats.CashStolen
	end,
}

local LeaderboardService = {}

local stores: { [string]: Store } = {}
local canWrite = false
local boards: { [string]: { Row } } = {}
local lastWritten: { [Player]: { [string]: number } } = {}
local names: { [number]: string } = {}

--------------------------------------------------------------------------------
-- Хранилища
--------------------------------------------------------------------------------

local function memoryStore(): Store
	local values: { [number]: number } = {}
	return {
		write = function(userId: number, value: number)
			values[userId] = value
		end,
		top = function(count: number): { Entry }?
			local list: { Entry } = {}
			for userId, value in values do
				table.insert(list, { userId = userId, value = value })
			end
			table.sort(list, function(a, b)
				if a.value ~= b.value then
					return a.value > b.value
				end
				return a.userId < b.userId
			end)
			while #list > count do
				table.remove(list)
			end
			return list
		end,
	}
end

local function dataStore(boardId: string): Store
	local store = DataStoreService:GetOrderedDataStore(STORE_PREFIX .. boardId .. STORE_VERSION)
	return {
		write = function(userId: number, value: number)
			local ok, message = pcall(function()
				store:SetAsync(tostring(userId), value)
			end)
			if not ok then
				warn(`[Leaderboard] Не удалось записать {boardId} для {userId}: {message}`)
			end
		end,
		top = function(count: number): { Entry }?
			local ok, result = pcall(function()
				return store:GetSortedAsync(false, count):GetCurrentPage()
			end)
			if not ok then
				warn(`[Leaderboard] Не удалось прочитать {boardId}: {result}`)
				return nil
			end
			local list: { Entry } = {}
			for _, item in result :: { any } do
				local userId = tonumber(item.key)
				if userId and typeof(item.value) == "number" then
					table.insert(list, { userId = userId, value = item.value })
				end
			end
			return list
		end,
	}
end

--------------------------------------------------------------------------------
-- Запись и чтение
--------------------------------------------------------------------------------

local function sanitize(value: number): number
	if value ~= value then
		return 0 -- NaN
	end
	return math.clamp(math.floor(value), 0, MAX_VALUE)
end

-- Записать значения игрока, которые изменились с прошлой записи.
local function writePlayer(player: Player)
	local data = DataService:get(player)
	if data == nil or not canWrite then
		return
	end
	names[player.UserId] = player.Name
	local written = lastWritten[player]
	if written == nil then
		written = {}
		lastWritten[player] = written
	end
	for boardId, store in stores do
		local value = sanitize(VALUE_OF[boardId](data))
		if written[boardId] ~= value then
			written[boardId] = value
			store.write(player.UserId, value)
		end
	end
end

local function nameOf(userId: number): string
	local cached = names[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local result = if ok and typeof(name) == "string" then name else `Игрок {userId}`
	names[userId] = result
	return result
end

local function readBoards()
	for boardId, store in stores do
		local entries = store.top(LeaderboardConfig.Size)
		if entries then
			local rows: { Row } = {}
			for _, entry in entries do
				table.insert(rows, { userId = entry.userId, name = nameOf(entry.userId), value = entry.value })
			end
			boards[boardId] = rows
		end
	end
end

local function refresh()
	for _, player in Players:GetPlayers() do
		writePlayer(player)
	end
	readBoards()
	NetService:fireAllClients("LeaderboardUpdate", boards)
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Можно ли писать в рейтинги. В Studio с настоящим DataStore — нельзя
-- (там работают чат-команды вроде /cash), только читать.
function LeaderboardService.writeAllowed(persistent: boolean, studio: boolean): boolean
	return not persistent or not studio
end

-- Текущий топ рейтинга (последнее прочитанное).
function LeaderboardService:getBoard(boardId: string): { Row }
	return table.clone(boards[boardId] or {})
end

-- Обновить сейчас (по расписанию это делает сам сервис).
function LeaderboardService:refresh()
	refresh()
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function LeaderboardService:Start()
	local persistent = DataService:isPersistent()
	canWrite = LeaderboardService.writeAllowed(persistent, RunService:IsStudio())
	for boardId in LeaderboardConfig.Boards do
		assert(VALUE_OF[boardId], `[Leaderboard] нет формулы для рейтинга {boardId}`)
		stores[boardId] = if persistent then dataStore(boardId) else memoryStore()
	end

	DataService:onLoaded(function(player: Player)
		names[player.UserId] = player.Name
		if next(boards) ~= nil then
			NetService:fireClient(player, "LeaderboardUpdate", boards)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Данные ещё на месте: DataService отпускает игрока отложенно (task.defer).
		writePlayer(player)
		lastWritten[player] = nil
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			writePlayer(player)
		end
	end)

	task.spawn(function()
		task.wait(LeaderboardConfig.FirstUpdateDelay)
		while true do
			xpcall(refresh, function(message: any)
				warn(`[Leaderboard] Ошибка обновления: {message}\n{debug.traceback()}`)
			end)
			task.wait(LeaderboardConfig.UpdateInterval)
		end
	end)
end

return LeaderboardService
