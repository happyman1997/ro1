--!strict
--[[
	Оружие игроков. Ключ — атрибут WeaponId на Tool-шаблоне в ServerStorage.Weapons
	и ключ в PlayerData.Equipment.Weapons.

	Урон по охране умножается на DefenderDamage класса, урон по мебели и стенам —
	на StructureDamage класса (Config/Classes). Урон по игрокам от класса не зависит.

	DrawTime — время доставания: оружие уже в руках (охрана его видит), но стрелять
	ещё нельзя. Это даёт охране первый выстрел против тех, кто заходит в ресторан
	без оружия и достаёт его внутри.
]]

export type WeaponInfo = {
	Name: string,
	Damage: number, -- урон по игрокам, охране и персоналу
	StructureDamage: number, -- урон по мебели, стенам и стеклу (с атрибутом MaxHealth)
	FireInterval: number, -- секунд между выстрелами
	Range: number, -- дальность, студы
	Spread: number, -- разброс, градусы
	DrawTime: number, -- секунд от взятия в руки до первого выстрела
	Scoped: boolean, -- оптический прицел: пока оружие в руках, над ним горит блик для всех
	Price: number, -- цена в будущем магазине (0 — выдаётся всем)
}

local Weapons: { [string]: WeaponInfo } = {
	Pistol = {
		Name = "Пистолет",
		Damage = 15,
		StructureDamage = 5,
		FireInterval = 0.3,
		Range = 150,
		Spread = 1.5,
		DrawTime = 0.4,
		Scoped = false,
		Price = 0,
	},
	Rifle = {
		Name = "Автомат",
		Damage = 12,
		StructureDamage = 6,
		FireInterval = 0.12,
		Range = 250,
		Spread = 3,
		DrawTime = 0.7,
		Scoped = false,
		Price = 8000,
	},
	Sniper = {
		Name = "Снайперская винтовка",
		Damage = 70,
		StructureDamage = 10,
		FireInterval = 1.5,
		Range = 600,
		Spread = 0.15,
		DrawTime = 1.2,
		Scoped = true,
		Price = 20000,
	},
}

for _, info in Weapons do
	table.freeze(info)
end

return table.freeze(Weapons)
