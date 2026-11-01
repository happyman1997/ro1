--!strict
--[[
	StateController — копия данных игрока на клиенте, для интерфейса.

	Источник правды — сервер. Клиент получает полный снимок при входе и затем
	отдельные изменения. Менять эти данные на клиенте бесполезно: сервер их
	не читает, а интерфейс просто покажет неправду.

	Пример (из UI или другого контроллера):
		local stop = StateController:observe("Cash", function(cash)
			label.Text = `${cash}`
		end)
		-- stop() — отписаться
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataTemplate = require(Shared:WaitForChild("DataTemplate"))
local Signal = require(Shared:WaitForChild("Signal"))
local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

type PlayerData = DataTemplate.PlayerData

local StateController = {}

-- (data) — пришёл полный снимок данных.
StateController.Loaded = Signal.new() :: Signal.Signal<PlayerData>
-- (key, value) — поле изменилось.
StateController.Changed = Signal.new() :: Signal.Signal<string, any>

local data: { [string]: any }? = nil

function StateController:isLoaded(): boolean
	return data ~= nil
end

-- Текущее значение поля (nil — данные ещё не пришли).
function StateController:get(key: string): any
	return if data then data[key] else nil
end

-- Вызвать callback сразу (если данные уже есть) и при каждом изменении поля key.
-- Возвращает функцию отписки.
function StateController:observe(key: string, callback: (value: any) -> ()): () -> ()
	if data then
		task.spawn(callback, data[key])
	end
	local loadedConnection = StateController.Loaded:Connect(function(newData: PlayerData)
		callback((newData :: any)[key])
	end)
	local changedConnection = StateController.Changed:Connect(function(changedKey: string, value: any)
		if changedKey == key then
			callback(value)
		end
	end)
	return function()
		loadedConnection:Disconnect()
		changedConnection:Disconnect()
	end
end

function StateController:Start()
	-- Одно событие для снимка и изменений: так они гарантированно приходят по порядку.
	Net.on("DataSync", function(kind: string, a: any, b: any)
		if kind == "Full" then
			data = a
			StateController.Loaded:Fire(a)
		elseif kind == "Set" then
			local current = data
			if current then
				current[a] = b
				StateController.Changed:Fire(a, b)
			end
		end
	end)
end

return StateController
