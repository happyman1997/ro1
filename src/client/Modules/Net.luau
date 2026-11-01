--!strict
--[[
	Net — сетевой слой клиента.

	Клиент НИЧЕГО не решает сам: он только просит сервер (fire) и показывает то,
	что сервер прислал (on). Проверки на клиенте нужны для удобства игрока
	(не отправлять заведомо неверный запрос, сразу показать подсказку),
	а не для защиты: читер обходит любой клиентский код.

	Пример:
		Net.fire("ChangeSetting", "ShowTips", false)
		Net.on("DataSync", function(kind, ...) ... end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local REMOTE_TIMEOUT = 15 -- секунд ожидания события от сервера

local folder = ReplicatedStorage:WaitForChild("Remotes")
local cache: { [string]: RemoteEvent } = {}

local function getRemote(name: string, direction: Remotes.Direction): RemoteEvent
	local info = Remotes[name]
	assert(info, `Net: событие «{name}» не объявлено в Shared/Remotes`)
	assert(info.direction == direction, `Net: «{name}» имеет направление {info.direction}`)

	local cached = cache[name]
	if cached then
		return cached
	end
	local instance = folder:WaitForChild(name, REMOTE_TIMEOUT)
	assert(instance, `Net: событие «{name}» не появилось за {REMOTE_TIMEOUT} с`)

	-- У UnreliableRemoteEvent те же методы, поэтому храним оба вида под одним типом.
	local remote = (instance :: any) :: RemoteEvent
	cache[name] = remote
	return remote
end

local Net = {}

-- Отправить запрос серверу (событие "ToServer").
function Net.fire(name: string, ...: any)
	getRemote(name, "ToServer"):FireServer(...)
end

-- Подписаться на сообщения сервера (событие "ToClient").
-- События, пришедшие до подписки, Roblox придержит и отдаст первому обработчику.
function Net.on(name: string, handler: (...any) -> ()): RBXScriptConnection
	return getRemote(name, "ToClient").OnClientEvent:Connect(handler)
end

return Net
