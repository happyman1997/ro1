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
]]

export type Direction = "ToClient" | "ToServer"
export type Kind = "Reliable" | "Unreliable"
export type RemoteInfo = { direction: Direction, kind: Kind }

local Remotes: { [string]: RemoteInfo } = {
	-- Данные игрока: полный снимок при входе ("Full", data) и изменения ("Set", key, value).
	DataSync = { direction = "ToClient", kind = "Reliable" },

	-- Игрок меняет свою настройку: (имя настройки, значение).
	ChangeSetting = { direction = "ToServer", kind = "Reliable" },
}

for _, info in Remotes do
	table.freeze(info)
end

return table.freeze(Remotes)
