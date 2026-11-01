--!strict
--[[
	ClassService — RPG-класс игрока и состояние маскировки стелса.

	Маскировка (isDisguised) действует, только если ВСЁ верно:
	  • класс с Disguise = true (Разведчик);
	  • оружие не в руках (по данным сервера);
	  • не раскрыт: достал оружие или пойман владельцем меньше N секунд назад;
	  • не взламывает кассу прямо сейчас.

	Раскрытие длится по времени, а не до момента, когда оружие убрано.
	Иначе работал бы трюк «достал, выстрелил, убрал — и снова невидим».

	Защита смены класса: только на территории своего ресторана и не чаще раза
	в CLASS_CHANGE_COOLDOWN. Иначе можно было бы зайти Танком в чужой ресторан
	и прямо у кассы переключиться в Разведчика.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Guard = require(ReplicatedStorage.Shared.Guard)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local DEFAULT_CLASS = "Assault"
local CLASS_CHANGE_COOLDOWN = 30
local DRAW_EXPOSE_DURATION = 15 -- стелс взял оружие в руки: маскировка слетает на столько секунд

local ClassService = {}

local exposedUntil: { [Player]: number } = {} -- os.clock()
local hacking: { [Player]: boolean } = {}
local lastChangeAt: { [Player]: number } = {}

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

function ClassService:getClassId(player: Player): string
	local data = DataService:get(player)
	local id = if data then data.Class else nil
	if id ~= nil and Classes[id] ~= nil then
		return id
	end
	return DEFAULT_CLASS
end

function ClassService:getClass(player: Player): Classes.ClassInfo
	return Classes[self:getClassId(player)]
end

function ClassService:canHack(player: Player): boolean
	return self:getClass(player).CanHack
end

function ClassService:isHacking(player: Player): boolean
	return hacking[player] == true
end

-- Вызывает CashRegisterService при начале и конце взлома.
function ClassService:setHacking(player: Player, value: boolean)
	hacking[player] = if value then true else nil
	player:SetAttribute("Hacking", value)
end

function ClassService:isExposed(player: Player): boolean
	return (exposedUntil[player] or 0) > os.clock()
end

-- Раскрыть маскировку на duration секунд (более короткое раскрытие не сокращает текущее).
-- Вызывают: смена оружия (здесь), касса (пойман владельцем), в будущем CombatService
-- (владелец или охрана нанесли урон).
function ClassService:expose(player: Player, duration: number, reason: string)
	local untilTime = os.clock() + duration
	if untilTime <= (exposedUntil[player] or 0) then
		return
	end
	exposedUntil[player] = untilTime
	-- Время сервера (GetServerTimeNow) понятно клиенту — для таймера в интерфейсе.
	player:SetAttribute("ExposedUntil", workspace:GetServerTimeNow() + duration)
	if self:getClass(player).Disguise then
		NetService:notify(player, `Маскировка раскрыта: {reason}`)
	end
end

function ClassService:isDisguised(player: Player): boolean
	if not self:getClass(player).Disguise or hacking[player] or self:isExposed(player) then
		return false
	end
	return CharacterUtil.getEquippedWeapon(player.Character) == nil
end

--------------------------------------------------------------------------------
-- Внутреннее
--------------------------------------------------------------------------------

local function setClassAttributes(player: Player)
	local class = ClassService:getClass(player)
	player:SetAttribute("Class", ClassService:getClassId(player))
	player:SetAttribute("CanHack", class.CanHack)
end

-- Применить характеристики класса к персонажу.
-- keepHealthFraction: при смене класса сохраняем долю здоровья,
-- иначе смена класса работала бы как бесплатное лечение.
local function applyStats(player: Player, keepHealthFraction: boolean)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end
	local class = ClassService:getClass(player)
	local fraction = if keepHealthFraction and humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
	humanoid.MaxHealth = class.MaxHealth
	humanoid.Health = class.MaxHealth * fraction
	-- Это только честная скорость. Клиент управляет своим персонажем и может её
	-- подменить — от спидхака защищает отдельная серверная проверка перемещения.
	humanoid.WalkSpeed = class.WalkSpeed
end

local function onCharacterAdded(player: Player, character: Model)
	exposedUntil[player] = nil -- новая жизнь — новая маскировка
	player:SetAttribute("ExposedUntil", nil)

	if character:WaitForChild("Humanoid", 10) then
		applyStats(player, false)
	end

	-- Оружие в руках: Tool появился в модели персонажа (на сервере).
	character.ChildAdded:Connect(function(child: Instance)
		if CharacterUtil.isWeapon(child) and ClassService:getClass(player).Disguise then
			ClassService:expose(player, DRAW_EXPOSE_DURATION, "оружие в руках")
		end
	end)
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function ClassService:Start()
	DataService:onLoaded(function(player: Player)
		setClassAttributes(player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		local character = player.Character
		if character then
			task.spawn(onCharacterAdded, player, character)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		exposedUntil[player] = nil
		hacking[player] = nil
		lastChangeAt[player] = nil
	end)

	NetService:on("SelectClass", {
		args = { Guard.keyOf(Classes) },
		rate = 1,
		burst = 3,
	}, function(player: Player, classId: string)
		if not DataService:isLoaded(player) or classId == ClassService:getClassId(player) then
			return
		end
		if hacking[player] then
			return
		end

		local now = os.clock()
		local remaining = CLASS_CHANGE_COOLDOWN - (now - (lastChangeAt[player] or -math.huge))
		if remaining > 0 then
			NetService:notify(player, `Сменить класс можно через {math.ceil(remaining)} с`)
			return
		end

		local plot = PlotService:getPlot(player)
		local _, _, root = CharacterUtil.getAlive(player)
		if plot == nil or root == nil or not PlotService:isInTerritory(plot, root.Position) then
			NetService:notify(player, "Сменить класс можно только на территории своего ресторана")
			return
		end

		lastChangeAt[player] = now
		DataService:set(player, "Class", classId)
		setClassAttributes(player)
		applyStats(player, true)
		NetService:notify(player, `Класс: {Classes[classId].Name}`)
	end)
end

return ClassService
