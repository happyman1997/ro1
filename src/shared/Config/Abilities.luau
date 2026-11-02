--!strict
--[[
	Способности классов (клавиша Q или кнопка в интерфейсе). У класса одна способность:
	ключ — поле Ability в Config/Classes.

	  Suppress (Штурмовик) — DURATION секунд его попадания по охране на 3 с снижают её точность.
	  Breach   (Подрывник) — пробивной заряд на стену или предмет в PlaceDistance студах:
	                         через FuseTime секунд взрыв в радиусе Radius. Ломает даже
	                         бронированные стены Tier 3–4 (ArmoredHealth), ранит людей.
	  Shield   (Танк)      — Duration секунд входящий урон меньше на Reduction.
	  Mark     (Разведчик) — подсвечивает чужую охрану в радиусе Radius на Duration секунд.
]]

export type AbilityInfo = {
	Name: string,
	Cooldown: number, -- секунд перезарядки
	Duration: number?,
	Reduction: number?,
	Radius: number?,
	FuseTime: number?,
	StructureDamage: number?,
	PlayerDamage: number?,
	PlaceDistance: number?,
}

local Abilities: { [string]: AbilityInfo } = {
	Suppress = { Name = "Подавление", Cooldown = 20, Duration = 6 },
	Breach = {
		Name = "Пробивной заряд",
		Cooldown = 25,
		FuseTime = 2,
		Radius = 8,
		StructureDamage = 300,
		PlayerDamage = 40,
		PlaceDistance = 8,
	},
	Shield = { Name = "Щит", Cooldown = 25, Duration = 5, Reduction = 0.7 },
	Mark = { Name = "Метка охраны", Cooldown = 15, Duration = 10, Radius = 60 },
}

for _, info in Abilities do
	table.freeze(info)
end

return table.freeze(Abilities)
