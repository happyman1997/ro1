--!strict
--[[
	Реестр всех сетевых событий игры. Единственное место, где они объявляются.

	Сервер (NetService) создаёт по этому списку объекты в ReplicatedStorage.Remotes,
	клиент (Net) берёт их оттуда. Опечатка в имени сразу даёт понятную ошибку,
	а не тихий баг.

	direction:
		"ToClient" — только сервер → клиент. Если клиент всё же отправит сюда
		             событие, NetService засчитает это как подозрительное действие.
		"ToServer" — только клиент → сервер. Обязательно нужен обработчик
		             NetService:on() с проверкой аргументов.
	kind:
		"Reliable"   — RemoteEvent: доставка и порядок гарантированы. Почти всё.
		"Unreliable" — UnreliableRemoteEvent: может теряться, зато дешевле.
		               Для частых некритичных данных (эффекты, направление взгляда).

	RemoteFunction сознательно не используем: InvokeClient позволяет клиенту
	«подвесить» серверный поток навсегда. Запрос с ответом делается парой событий.

	Взаимодействие с кассой идёт через ProximityPrompt, а не через Remote.
	Для сервера это такой же ввод от клиента и проверяется так же строго
	(см. CashRegisterService).
]]

export type Direction = "ToClient" | "ToServer"
export type Kind = "Reliable" | "Unreliable"
export type RemoteInfo = { direction: Direction, kind: Kind }

local Remotes: { [string]: RemoteInfo } = {
	-- Данные игрока: полный снимок при входе ("Full", data) и изменения ("Set", key, value).
	DataSync = { direction = "ToClient", kind = "Reliable" },
	-- Текстовое уведомление игроку: (text).
	Notify = { direction = "ToClient", kind = "Reliable" },
	-- Состояние взлома для вора: ("Started", endsAtServerTime) | ("Ended", success).
	HackState = { direction = "ToClient", kind = "Reliable" },
	-- Выстрел (охраны или игрока) для эффекта трассера: (origin: Vector3, impact: Vector3).
	ShotFired = { direction = "ToClient", kind = "Unreliable" },
	-- Взрыв заряда для эффекта: (center: Vector3, radius: number).
	ExplosionFx = { direction = "ToClient", kind = "Unreliable" },
	-- Метка разведчика: (защитники: { Model }, длительность: number).
	MarkDefenders = { direction = "ToClient", kind = "Reliable" },
	-- Приглашение в группу: (userId пригласившего, имя).
	PartyInvite = { direction = "ToClient", kind = "Reliable" },
	-- Состав группы: ({ userId }); пустой список — не в группе.
	PartyUpdate = { direction = "ToClient", kind = "Reliable" },
	-- Глобальные рейтинги: ({ [boardId]: { { userId, name, value } } }).
	LeaderboardUpdate = { direction = "ToClient", kind = "Reliable" },

	-- Игрок меняет свою настройку: (имя настройки, значение).
	ChangeSetting = { direction = "ToServer", kind = "Reliable" },
	-- Выбор класса: (classId). Только на территории своего ресторана.
	SelectClass = { direction = "ToServer", kind = "Reliable" },
	-- Улучшить ресторан до следующего уровня: ().
	UpgradeRestaurant = { direction = "ToServer", kind = "Reliable" },
	-- Оплатить ремонт после штурма: ().
	RepairRestaurant = { direction = "ToServer", kind = "Reliable" },
	-- Выстрел из оружия в руках: (направление прицела: Vector3). Всё остальное считает сервер.
	Fire = { direction = "ToServer", kind = "Reliable" },
	-- Нанять охрану в слот своего ресторана: (slotId, defenderType).
	HireDefender = { direction = "ToServer", kind = "Reliable" },
	-- Уволить охрану из слота: (slotId).
	DismissDefender = { direction = "ToServer", kind = "Reliable" },
	-- Купить оружие: (weaponId).
	BuyWeapon = { direction = "ToServer", kind = "Reliable" },
	-- Применить способность класса: (точка прицела: Vector3?).
	UseAbility = { direction = "ToServer", kind = "Reliable" },
	-- Пригласить игрока в группу: (userId).
	InviteToParty = { direction = "ToServer", kind = "Reliable" },
	-- Ответить на приглашение: (userId пригласившего, принять: boolean).
	RespondPartyInvite = { direction = "ToServer", kind = "Reliable" },
	-- Выйти из группы: ().
	LeaveParty = { direction = "ToServer", kind = "Reliable" },
}

for _, info in Remotes do
	table.freeze(info)
end

return table.freeze(Remotes)
