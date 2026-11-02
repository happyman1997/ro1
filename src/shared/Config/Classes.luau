--!strict
--[[
	RPG-классы. Ключ хранится в данных игрока (PlayerData.Class).
	Роли классов в штурме описаны в docs/ARCHITECTURE.md, раздел «Классы».

	Множители урона (StructureDamage, DefenderDamage) применяет будущий
	CombatService. Здесь они заданы, чтобы баланс жил в одном месте.
]]

export type ClassInfo = {
	Name: string,
	Role: string,
	MaxHealth: number,
	WalkSpeed: number,
	CanHack: boolean, -- может взламывать кассы
	Disguise: boolean, -- маскировка: с убранным оружием турели не видят, охрана считает клиентом
	Threat: number, -- приоритет цели у охраны: чем больше, тем раньше стреляют именно в него
	StructureDamage: number, -- множитель урона по стенам, дверям, мебели
	DefenderDamage: number, -- множитель урона по охране и турелям
	Ability: string, -- ключ из Config/Abilities
}

local Classes: { [string]: ClassInfo } = {
	Assault = {
		Name = "Штурмовик",
		Role = "Зачистка охраны",
		MaxHealth = 120,
		WalkSpeed = 16,
		CanHack = false,
		Disguise = false,
		Threat = 1,
		StructureDamage = 1,
		DefenderDamage = 1.5,
		Ability = "Suppress",
	},
	Demolition = {
		Name = "Подрывник",
		Role = "Пролом стен и дверей",
		MaxHealth = 100,
		WalkSpeed = 15,
		CanHack = false,
		Disguise = false,
		Threat = 1,
		StructureDamage = 3,
		DefenderDamage = 0.8,
		Ability = "Breach",
	},
	Tank = {
		Name = "Танк",
		Role = "Принимает огонь на себя",
		MaxHealth = 300,
		WalkSpeed = 13,
		CanHack = false,
		Disguise = false,
		Threat = 3,
		StructureDamage = 1,
		DefenderDamage = 1,
		Ability = "Shield",
	},
	Stealth = {
		Name = "Разведчик",
		Role = "Тихий взлом касс",
		MaxHealth = 80,
		WalkSpeed = 18,
		CanHack = true,
		Disguise = true,
		Threat = 0.8,
		StructureDamage = 0.5,
		DefenderDamage = 0.8,
		Ability = "Mark",
	},
}

for _, info in Classes do
	table.freeze(info)
end

return table.freeze(Classes)
