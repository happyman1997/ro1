--!strict
--[[
	Миграции формата данных игрока.

	Migrations[N] — функция, которая переводит данные из версии N в версию N+1,
	изменяя таблицу на месте. После всех миграций DataService дополняет данные
	недостающими полями из шаблона, поэтому для ПРОСТОГО ДОБАВЛЕНИЯ поля
	миграция не нужна.

	Пример: переименовали Coins в Gold (версия 1 → 2).
		[1] = function(data)
			data.Gold = data.Coins
			data.Coins = nil
		end,
	и в DataTemplate поставили Version = 2.

	Миграции не удаляйте, пока в DataStore могут лежать старые сохранения.
]]

local Migrations: { [number]: (data: { [string]: any }) -> () } = {}

return Migrations
