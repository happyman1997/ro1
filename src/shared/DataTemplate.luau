--!strict
--[[
	Шаблон данных игрока — то, что сохраняется в DataStore.

	Модуль лежит в Shared, чтобы клиент знал форму данных (типы для интерфейса).
	Значения по умолчанию не секретны. Изменять данные может ТОЛЬКО сервер
	через DataService.

	Как добавить поле:
		1. Добавьте его в тип PlayerData и в Template ниже. Старые сохранения
		   получат значение по умолчанию автоматически, миграция не нужна.
		2. Если меняется смысл или формат СУЩЕСТВУЮЩЕГО поля, увеличьте Version
		   и напишите миграцию в ServerScriptService.Server.Modules.Migrations.

	Массивы в шаблоне оставляйте пустыми ({}): содержимое массивов при
	дополнении старых сохранений не копируется, иначе проданный предмет
	«вернулся» бы игроку.

	Что НЕЛЬЗЯ хранить: Instance, Vector3, CFrame, Color3 (храните числами),
	NaN и бесконечность, смешанные таблицы (массив + словарь), массивы с дырами,
	строки с некорректным UTF-8. DataService проверяет это при каждом изменении.
	Предел — 4 МБ на игрока.
]]

export type Settings = {
	MusicVolume: number, -- громкость музыки, 0..1
	ShowTips: boolean, -- показывать подсказки
}

export type Stats = {
	FirstJoin: number, -- os.time() первого входа
	LastJoin: number, -- os.time() последнего входа
	Logins: number, -- сколько раз заходил
}

export type PlayerData = {
	Version: number,
	Coins: number,
	Settings: Settings,
	Stats: Stats,
}

local function deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value :: any do
			deepFreeze(child)
		end
		table.freeze(value)
	end
	return value
end

local DataTemplate = {}

-- Текущая версия формата данных (см. Migrations).
DataTemplate.Version = 1

DataTemplate.Template = deepFreeze({
	Version = DataTemplate.Version,
	Coins = 0,
	Settings = {
		MusicVolume = 0.5,
		ShowTips = true,
	},
	Stats = {
		FirstJoin = 0,
		LastJoin = 0,
		Logins = 0,
	},
} :: PlayerData)

-- Поля, которые сервер НЕ отправляет клиенту (служебные данные:
-- например, id уже обработанных покупок или скрытые счётчики анти-чита).
DataTemplate.PrivateKeys = table.freeze({}) :: { [string]: boolean }

return table.freeze(DataTemplate)
