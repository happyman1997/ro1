--!strict
--[[
	SettingsService — образец запроса клиент → сервер с полной проверкой.

	Клиент присылает (имя настройки, значение). Сервер:
	  1. ограничивает частоту запросов (NetService);
	  2. проверяет, что имя есть в списке разрешённых (Guard.keyOf);
	  3. проверяет значение правилом именно этой настройки;
	  4. только потом сохраняет через DataService.

	По этому образцу пишутся все запросы игроков: покупка, использование
	предмета, выбор класса и т. д.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Guard = require(ReplicatedStorage.Shared.Guard)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)

-- Правило проверки для каждой настройки. Нет в списке — менять нельзя.
local RULES: { [string]: Guard.Check } = {
	MusicVolume = Guard.number(0, 1),
	ShowTips = Guard.boolean(),
}

local SettingsService = {}

function SettingsService:Start()
	NetService:on("ChangeSetting", {
		args = { Guard.keyOf(RULES), Guard.any() }, -- значение проверяем ниже: правило зависит от имени
		rate = 5,
		burst = 10,
	}, function(player: Player, name: string, value: unknown)
		if not RULES[name](value) then
			NetService:flag(player, `недопустимое значение настройки «{name}»`, NetService.Penalty.BadRequest)
			return
		end
		if not DataService:isLoaded(player) then
			return -- данные ещё грузятся; клиент повторит после загрузки
		end

		DataService:update(player, "Settings", function(settings)
			settings[name] = value
			return settings
		end)
	end)
end

return SettingsService
