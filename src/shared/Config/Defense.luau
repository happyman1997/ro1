--!strict
--[[
	Типы охраны ресторана. Ключ — значение атрибута DefenderType на модели.

	Detection — кого защитник считает целью на территории ресторана:
		"Armed"    — люди-охранники: чужой игрок с оружием в руках, раскрытый
		             или взламывающий кассу стелс. Игрока с убранным оружием
		             принимают за клиента.
		"Intruder" — автоматика (турели): любой чужой игрок, КРОМЕ стелса
		             в маскировке (оружие убрано, не раскрыт, не взламывает).
	Игроков из «памяти тревоги» (напали, засветились) атакуют все.
	Таблица правил целиком — в docs/ARCHITECTURE.md, раздел «Охрана».
]]

export type Kind = "Guard" | "Turret"
export type Detection = "Armed" | "Intruder"

export type DefenderInfo = {
	Name: string,
	Kind: Kind, -- Guard — модель с Humanoid, Turret — без
	Detection: Detection,
	Cost: number, -- цена найма (для будущего DefenseService)
	MinTier: number, -- минимальный уровень ресторана
	MaxHealth: number,
	Range: number, -- дальность обзора, студы
	FieldOfView: number, -- угол обзора в градусах; 360 — видит во все стороны
	Damage: number, -- урон за попадание / удар
	FireInterval: number, -- секунд между атаками
	Accuracy: number, -- шанс попадания 0..1
	Melee: boolean, -- ближний бой: догоняет цель
	LeashRadius: number, -- насколько далеко от поста может уйти (только Melee)
}

local Defense: { [string]: DefenderInfo } = {
	Bouncer = {
		Name = "Вышибала",
		Kind = "Guard",
		Detection = "Armed",
		Cost = 1500,
		MinTier = 1,
		MaxHealth = 250,
		Range = 30,
		FieldOfView = 140,
		Damage = 20,
		FireInterval = 1,
		Accuracy = 1,
		Melee = true,
		LeashRadius = 25,
	},
	Gunner = {
		Name = "Охранник с пистолетом",
		Kind = "Guard",
		Detection = "Armed",
		Cost = 4000,
		MinTier = 2,
		MaxHealth = 150,
		Range = 70,
		FieldOfView = 120,
		Damage = 9,
		FireInterval = 0.4,
		Accuracy = 0.6,
		Melee = false,
		LeashRadius = 0,
	},
	CeilingTurret = {
		Name = "Потолочная турель",
		Kind = "Turret",
		Detection = "Intruder",
		Cost = 10000,
		MinTier = 3,
		MaxHealth = 400,
		Range = 45,
		FieldOfView = 360,
		Damage = 6,
		FireInterval = 0.2,
		Accuracy = 0.5,
		Melee = false,
		LeashRadius = 0,
	},
}

for _, info in Defense do
	table.freeze(info)
end

return table.freeze(Defense)
