--!strict
--[[
	LeaderboardController — последние глобальные рейтинги от сервера
	(событие LeaderboardUpdate) для панели «Рейтинг».
	Данные только для показа: рейтинги считает и хранит сервер.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal"))
local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

export type Row = { userId: number, name: string, value: number }

local LeaderboardController = {}

-- Рейтинги обновились.
LeaderboardController.Changed = Signal.new() :: Signal.Signal<()>

local boards: { [string]: { Row } } = {}

function LeaderboardController:getBoard(boardId: string): { Row }
	return boards[boardId] or {}
end

-- Проверить присланную строку: сервер свой, но формат проверяем всегда.
local function toRow(raw: unknown): Row?
	if typeof(raw) ~= "table" then
		return nil
	end
	local item = raw :: { [string]: unknown }
	local userId, name, value = item.userId, item.name, item.value
	if typeof(userId) == "number" and typeof(name) == "string" and typeof(value) == "number" then
		return { userId = userId, name = name, value = value }
	end
	return nil
end

function LeaderboardController:Start()
	Net.on("LeaderboardUpdate", function(raw: unknown)
		if typeof(raw) ~= "table" then
			return
		end
		local fresh: { [string]: { Row } } = {}
		for boardId, list in raw :: { [unknown]: unknown } do
			if typeof(boardId) == "string" and typeof(list) == "table" then
				local rows = {}
				for _, item in list :: { unknown } do
					local row = toRow(item)
					if row then
						table.insert(rows, row)
					end
				end
				fresh[boardId] = rows
			end
		end
		boards = fresh
		LeaderboardController.Changed:Fire()
	end)
end

return LeaderboardController
