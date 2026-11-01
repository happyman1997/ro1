--!strict
--[[
	Миграции формата данных игрока.

	Migrations[N] — функция, которая переводит данные из версии N в версию N+1,
	изменяя таблицу на месте. После всех миграций DataService дополняет данные
	недостающими полями из шаблона, поэтому для ПРОСТОГО ДОБАВЛЕНИЯ поля
	миграция не нужна.

	Миграции не удаляйте, пока в DataStore могут лежать старые сохранения.
]]

local Migrations: { [number]: (data: { [string]: any }) -> () } = {
	-- 1 → 2: валюта каркаса Coins переименована в Cash.
	[1] = function(data)
		data.Cash = if type(data.Coins) == "number" then data.Coins else 0
		data.Coins = nil
	end,
}

return Migrations
