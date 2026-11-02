--!strict
--[[
	ShopService — покупка оружия за Cash.

	BuyWeapon(weaponId): оружие с ценой больше нуля, которого ещё нет, — деньги
	списываются, оружие навсегда добавляется в снаряжение и сразу выдаётся
	(WeaponService:giveWeapon).

	ЗАЩИТА:
	• Цена берётся из Config/Weapons на сервере, клиент присылает только id.
	• Проверка денег и списание без yield между ними: пачкой одинаковых
	  запросов дважды не купить и не уйти в минус.
	• Неизвестный id отклоняет NetService (Guard.keyOf) и засчитывает как подозрительный.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Guard = require(ReplicatedStorage.Shared.Guard)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local WeaponService = require(script.Parent.WeaponService)

local ShopService = {}

-- Купить оружие. Возвращает true при успехе.
function ShopService:buyWeapon(player: Player, weaponId: string): boolean
	local info = Weapons[weaponId]
	local data = DataService:get(player)
	if info == nil or data == nil then
		return false
	end
	if info.Price <= 0 then
		NetService:notify(player, `«{info.Name}» выдаётся всем бесплатно`)
		return false
	end
	if data.Equipment.Weapons[weaponId] ~= nil then
		NetService:notify(player, `«{info.Name}» уже куплен`)
		return false
	end
	if data.Cash < info.Price then
		NetService:notify(player, `«{info.Name}» стоит ${info.Price}`)
		return false
	end

	DataService:increment(player, "Cash", -info.Price)
	WeaponService:giveWeapon(player, weaponId)
	NetService:notify(player, `Куплено: {info.Name}`)
	return true
end

function ShopService:Start()
	NetService:on("BuyWeapon", {
		args = { Guard.keyOf(Weapons) },
		rate = 2,
		burst = 4,
	}, function(player: Player, weaponId: string)
		ShopService:buyWeapon(player, weaponId)
	end)
end

return ShopService
