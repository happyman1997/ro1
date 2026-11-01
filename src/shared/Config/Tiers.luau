--!strict
--[[
	Уровни ресторана. Индекс в массиве = номер уровня.

	Model — имя модели-шаблона в ServerStorage.Restaurants (структура модели
	описана в docs/ARCHITECTURE.md, раздел «Сцена»).
	Все суммы и времена — стартовый баланс, его подбирают по плейтестам.
]]

export type TierInfo = {
	Name: string,
	Model: string,
	UpgradeCost: number, -- цена перехода на этот уровень с предыдущего
	IncomePerSecond: number, -- доход работающего ресторана
	RegisterCapacity: number, -- больше в кассу не помещается: стимул чаще забирать выручку
	RepairCost: number, -- цена ремонта после штурма
	HackDuration: number, -- секунд на взлом кассы стелсом
}

local Tiers: { TierInfo } = {
	{
		Name = "Деревянный ларёк",
		Model = "Tier1",
		UpgradeCost = 0,
		IncomePerSecond = 4,
		RegisterCapacity = 1200,
		RepairCost = 150,
		HackDuration = 8,
	},
	{
		Name = "Кирпичное кафе",
		Model = "Tier2",
		UpgradeCost = 6000,
		IncomePerSecond = 12,
		RegisterCapacity = 5000,
		RepairCost = 600,
		HackDuration = 12,
	},
	{
		Name = "Современный ресторан",
		Model = "Tier3",
		UpgradeCost = 30000,
		IncomePerSecond = 30,
		RegisterCapacity = 15000,
		RepairCost = 2500,
		HackDuration = 16,
	},
	{
		Name = "Укреплённый бункер",
		Model = "Tier4",
		UpgradeCost = 120000,
		IncomePerSecond = 75,
		RegisterCapacity = 45000,
		RepairCost = 8000,
		HackDuration = 20,
	},
}

for _, tier in Tiers do
	table.freeze(tier)
end

return table.freeze(Tiers)
