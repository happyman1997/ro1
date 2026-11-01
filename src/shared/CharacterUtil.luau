--!strict
--[[
	CharacterUtil — общие проверки персонажа.

	Оружие в руках = Tool, лежащий прямо в модели персонажа (так Roblox
	представляет экипированный инструмент). Правило «закрытое по умолчанию»:
	ЛЮБОЙ Tool считается оружием, если на нём нет тега "Harmless". Новое
	оружие, которое забыли пометить, охрана всё равно увидит. Ошибка в обратную
	сторону (невидимое оружие) была бы подарком читерам.

	Сервер видит экипировку так, как её видит сервер. Пока оружие не в руках
	на сервере, им нельзя стрелять: это обязан проверять WeaponService.
	Тогда «спрятать оружие от охраны» и «стрелять» физически несовместимы.
]]

local CollectionService = game:GetService("CollectionService")

local HARMLESS_TAG = "Harmless"

local CharacterUtil = {}

-- Персонаж, Humanoid и корневая деталь живого игрока (иначе три nil).
function CharacterUtil.getAlive(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil, nil
	end
	local root = humanoid.RootPart
	if root == nil then
		return nil, nil, nil
	end
	return character, humanoid, root
end

function CharacterUtil.isWeapon(instance: Instance): boolean
	return instance:IsA("Tool") and not CollectionService:HasTag(instance, HARMLESS_TAG)
end

-- Оружие в руках персонажа или nil. Перебираем всех детей, а не первый Tool:
-- эксплойт может положить в персонажа несколько инструментов сразу.
function CharacterUtil.getEquippedWeapon(character: Model?): Tool?
	if character == nil then
		return nil
	end
	for _, child in character:GetChildren() do
		if CharacterUtil.isWeapon(child) then
			return child :: Tool
		end
	end
	return nil
end

return table.freeze(CharacterUtil)
