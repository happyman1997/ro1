--!strict
--[[
	Глобальные рейтинги (OrderedDataStore). Читают сервер (LeaderboardService)
	и клиент (панель «Рейтинг»). Что именно считается в каждом рейтинге,
	решает сервер; здесь только названия и порядок.
]]

export type BoardInfo = {
	Title: string,
	Order: number, -- порядок в интерфейсе
}

local Boards: { [string]: BoardInfo } = {
	Richest = { Title = "Самые богатые", Order = 1 },
	Thieves = { Title = "Лучшие воры", Order = 2 },
}

for _, info in Boards do
	table.freeze(info)
end

return table.freeze({
	Size = 10, -- мест в каждом рейтинге
	UpdateInterval = 180, -- секунд между обновлениями (запись своих игроков и чтение топа)
	FirstUpdateDelay = 5, -- первое обновление после запуска сервера
	Boards = table.freeze(Boards),
})
