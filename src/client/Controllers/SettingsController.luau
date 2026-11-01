--!strict
--[[
	SettingsController — чтение и изменение настроек игрока с клиента.

	Пример:
		SettingsController:set("MusicVolume", 0.3)
		print(SettingsController:get("ShowTips"))

	set() только просит сервер. Новое значение вернётся через StateController,
	когда сервер его проверит и сохранит. Для ползунков отправляйте значение,
	когда игрок отпустил ползунок, а не на каждый кадр: сервер ограничивает
	частоту запросов.
]]

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))
local StateController = require(script.Parent:WaitForChild("StateController"))

local SettingsController = {}

function SettingsController:get(name: string): any
	local settings = StateController:get("Settings")
	return if settings then settings[name] else nil
end

function SettingsController:set(name: string, value: any)
	Net.fire("ChangeSetting", name, value)
end

return SettingsController
