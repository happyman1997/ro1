--!strict
--[[
	Шаблон данных игрока — то, что сохраняется в DataStore (одна запись на игрока).

	Модуль лежит в Shared, чтобы клиент знал форму данных (типы для интерфейса).
	Значения по умолчанию не секретны. Изменять данные может ТОЛЬКО сервер
	через DataService.

	Что НЕ хранится здесь (живёт только в памяти сервера, см. docs/ARCHITECTURE.md):
	деньги в кассе, сломанная мебель, убитый персонал, тревога охраны,
	раскрытие стелса, номер участка. Это состояние текущей сессии.

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
	Robberies: number, -- успешных взломов чужих касс
	TimesRobbed: number, -- сколько раз взломали его кассу
	CashStolen: number, -- всего украдено
}

export type RestaurantData = {
	Tier: number, -- текущий уровень ресторана (1..#Tiers)
	NeedsRepair: boolean, -- ресторан сломан; сохраняется, чтобы перезаход не чинил его бесплатно
	Defense: { [string]: string }, -- SlotId слота → DefenderType нанятого защитника
}

export type Equipment = {
	Weapons: { [string]: number }, -- id купленного оружия → уровень прокачки
}

export type PlayerData = {
	Version: number,
	Cash: number, -- кошелёк игрока (деньги из кассы зачисляются сюда)
	Class: string, -- ключ из Config/Classes
	Restaurant: RestaurantData,
	Equipment: Equipment,
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
DataTemplate.Version = 2

DataTemplate.Template = deepFreeze({
	Version = DataTemplate.Version,
	Cash = 0,
	Class = "Assault",
	Restaurant = {
		Tier = 1,
		NeedsRepair = false,
		Defense = {},
	},
	Equipment = {
		Weapons = {
			Pistol = 1, -- стартовое оружие, есть у всех
		},
	},
	Settings = {
		MusicVolume = 0.5,
		ShowTips = true,
	},
	Stats = {
		FirstJoin = 0,
		LastJoin = 0,
		Logins = 0,
		Robberies = 0,
		TimesRobbed = 0,
		CashStolen = 0,
	},
} :: PlayerData)

-- Поля, которые сервер НЕ отправляет клиенту (служебные данные:
-- например, id уже обработанных покупок или скрытые счётчики анти-чита).
DataTemplate.PrivateKeys = table.freeze({}) :: { [string]: boolean }

return table.freeze(DataTemplate)
