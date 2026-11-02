--!strict
--[[
	WeaponService — оружие игроков: выдача, стрельба, урон, блик прицела.

	Выдача: при появлении персонажа в рюкзак кладутся копии шаблонов из
	ServerStorage.Weapons для каждого оружия из PlayerData.Equipment.Weapons.

	Выстрел (событие Fire): клиент присылает ТОЛЬКО направление прицела.
	Сервер сам:
	  1. берёт оружие, которое в руках у персонажа по данным сервера;
	  2. проверяет время доставания (DrawTime) и темп стрельбы (FireInterval);
	  3. пускает луч от головы персонажа (позицию от клиента не принимаем)
	     с разбросом и дальностью оружия;
	  4. пули проходят сквозь детали с атрибутом ShootThrough (доски ларька),
	     но останавливаются на кирпиче, бронестекле, персонажах;
	  5. наносит урон и сообщает охране участка о нападении.

	Урон:
	  • игроки — Damage оружия;
	  • охрана и турели (теги Guard/Turret) — Damage × DefenderDamage класса;
	  • персонал (тег Staff) — Damage;
	  • разрушаемое (атрибут MaxHealth: мебель, деревянные стены, обычное стекло) —
	    StructureDamage × StructureDamage класса. При нуле — атрибут Broken:
	    мебель останавливает ресторан, стены и стекло исчезают (открывают проход).
	  Своё (свой ресторан, своя охрана) не повреждается.

	Блик прицела: оружию с Scoped = true при взятии в руки сервер добавляет
	яркий BillboardGui. Он создан на сервере, поэтому виден всем; клиент может
	удалить блик только у себя на экране.

	ЗАЩИТА:
	• Направление проверяется (конечный вектор); дальность, разброс и урон берутся
	  из конфига на сервере.
	• Начало луча — голова персонажа на сервере: нельзя «стрелять» из другой точки
	  или сквозь стену, у которой стоишь.
	• Оружие должно быть в руках на сервере: спрятать его от охраны и стрелять
	  одновременно невозможно.
	• Время доставания и темп стрельбы считает сервер; частые запросы режет NetService.
	• Ограничение: направление прицела задаёт клиент, поэтому аимбот так не закрыть.
	  Против него нужна статистика попаданий (в планах).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Destruction = require(script.Parent.Parent.Modules.Destruction)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)
local AbilityService = require(script.Parent.AbilityService)
local ClassService = require(script.Parent.ClassService)
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local GuardAIService = require(script.Parent.GuardAIService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)

local TEMPLATES_FOLDER = "Weapons"
local GLINT_NAME = "ScopeGlint"
local MAX_PASSES = 6 -- сколько простреливаемых деталей подряд может пройти пуля
local SHOT_EFFECT_RADIUS = 300
-- Допуск темпа стрельбы: пакеты с выстрелами могут прийти пачкой из-за пинга.
local FIRE_INTERVAL_TOLERANCE = 0.85
local DEFENDER_TAGS = { "Guard", "Turret" }
local STAFF_TAGS = { "Staff" }
local SUPPRESS_EFFECT = 3 -- секунд, на которые подавление снижает точность охранника

type WeaponInfo = Weapons.WeaponInfo

type ShooterState = {
	equippedAt: { [Instance]: number }, -- когда каждый Tool взяли в руки (os.clock)
	lastShotAt: number,
}

local WeaponService = {}

local templates: Instance? = nil
local shooters: { [Player]: ShooterState } = {}
local random = Random.new()

--------------------------------------------------------------------------------
-- Вспомогательное
--------------------------------------------------------------------------------

local function weaponOf(tool: Instance): (string?, WeaponInfo?)
	local id = tool:GetAttribute("WeaponId")
	if typeof(id) == "string" and Weapons[id] ~= nil then
		return id, Weapons[id]
	end
	return nil, nil
end

local function stateOf(player: Player): ShooterState
	local state = shooters[player]
	if state == nil then
		state = { equippedAt = {}, lastShotAt = -math.huge }
		shooters[player] = state
	end
	return state
end

local findTaggedAncestor = Destruction.findTaggedAncestor

-- Отклонить направление на случайный угол не больше degrees.
local function applySpread(direction: Vector3, degrees: number): Vector3
	if degrees <= 0 then
		return direction
	end
	local angle = math.rad(degrees) * math.sqrt(random:NextNumber())
	local roll = random:NextNumber() * math.pi * 2
	local frame = CFrame.lookAt(Vector3.new(0, 0, 0), direction)
	return (frame * CFrame.Angles(0, 0, roll) * CFrame.Angles(angle, 0, 0)).LookVector
end

local function reportAggression(plot: PlotService.Plot?, shooter: Player)
	if plot then
		GuardAIService:reportAggression(plot, shooter)
	end
end

--------------------------------------------------------------------------------
-- Урон
--------------------------------------------------------------------------------

local function applyHit(shooter: Player, info: WeaponInfo, part: BasePart)
	-- Игрок
	local model = part:FindFirstAncestorOfClass("Model")
	local victim = if model then Players:GetPlayerFromCharacter(model) else nil
	if victim then
		if victim == shooter or model == nil then
			return
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if CombatService:damagePlayer(victim, info.Damage, shooter) > 0 and humanoid then
			-- Напал на хозяина у него на территории — охрана хозяина отвечает.
			local plot = PlotService:getPlot(victim)
			local root = humanoid.RootPart
			if plot and root and PlotService:isInTerritory(plot, root.Position) then
				reportAggression(plot, shooter)
			end
		end
		return
	end

	local plot = PlotService:getPlotFromInstance(part)
	if plot and PlotService:isFriendly(plot, shooter) then
		return -- свой ресторан и своя охрана не повреждаются
	end
	local class = ClassService:getClass(shooter)

	-- Охрана и турели
	local defender = findTaggedAncestor(part, DEFENDER_TAGS)
	if defender then
		Destruction.damageDefender(defender, info.Damage * class.DefenderDamage)
		if AbilityService:isSuppressing(shooter) then
			defender:SetAttribute("SuppressedUntil", workspace:GetServerTimeNow() + SUPPRESS_EFFECT)
		end
		reportAggression(plot, shooter)
		return
	end

	-- Персонал
	local staff = findTaggedAncestor(part, STAFF_TAGS)
	if staff then
		Destruction.damageDefender(staff, info.Damage)
		reportAggression(plot, shooter)
		return
	end

	-- Мебель, стены, стекло
	local target = Destruction.find(part, false)
	if target and Destruction.damage(target, info.StructureDamage * class.StructureDamage, false) then
		reportAggression(plot, shooter)
	end
end

-- Пустить пулю. Возвращает точку, где она остановилась (для трассера).
local function traceShot(
	shooter: Player,
	character: Model,
	info: WeaponInfo,
	origin: Vector3,
	direction: Vector3
): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	for _ = 1, MAX_PASSES do
		local result = workspace:Raycast(origin, direction, params)
		if result == nil then
			return origin + direction
		end
		local hit = result.Instance
		applyHit(shooter, info, hit)
		if hit:GetAttribute("ShootThrough") == true then
			params:AddToFilter(hit) -- пуля прошла насквозь и летит дальше
		else
			return result.Position
		end
	end
	return origin + direction
end

local function onFire(player: Player, aim: Vector3)
	local character, _, root = CharacterUtil.getAlive(player)
	if character == nil or root == nil then
		return
	end
	local tool = CharacterUtil.getEquippedWeapon(character)
	if tool == nil then
		return -- оружие убрали между кликом и пакетом — это не чит
	end
	local _, info = weaponOf(tool)
	if info == nil then
		return
	end
	if aim.Magnitude < 0.5 then
		NetService:flag(
			player,
			"выстрел с нулевым направлением",
			NetService.Penalty.BadRequest
		)
		return
	end

	local state = stateOf(player)
	local now = os.clock()
	local equippedAt = state.equippedAt[tool]
	if equippedAt == nil or now - equippedAt < info.DrawTime then
		return -- оружие ещё достают
	end
	if now - state.lastShotAt < info.FireInterval * FIRE_INTERVAL_TOLERANCE then
		return -- быстрее темпа оружия
	end
	state.lastShotAt = now

	local head = character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") then (head :: BasePart).Position else root.Position
	local direction = applySpread(aim.Unit, info.Spread) * info.Range
	local impact = traceShot(player, character, info, origin, direction)
	NetService:fireNearby(origin, SHOT_EFFECT_RADIUS, player, "ShotFired", origin, impact)
end

--------------------------------------------------------------------------------
-- Выдача и блик
--------------------------------------------------------------------------------

local function addGlint(tool: Instance)
	local handle = tool:FindFirstChild("Handle")
	if handle == nil or handle:FindFirstChild(GLINT_NAME) then
		return
	end
	local glint = Instance.new("BillboardGui")
	glint.Name = GLINT_NAME
	glint.Size = UDim2.new(3, 0, 3, 0) -- размер в студах: заметно издалека
	glint.AlwaysOnTop = true -- виден сквозь листву и укрытия
	glint.LightInfluence = 0
	glint.MaxDistance = 2000
	local flare = Instance.new("Frame")
	flare.Size = UDim2.fromScale(1, 1)
	flare.BackgroundColor3 = Color3.fromRGB(255, 250, 210)
	flare.BackgroundTransparency = 0.05
	flare.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = flare
	flare.Parent = glint
	glint.Parent = handle
end

local function removeGlint(tool: Instance)
	local handle = tool:FindFirstChild("Handle")
	local glint = if handle then handle:FindFirstChild(GLINT_NAME) else nil
	if glint then
		glint:Destroy()
	end
end

local function hasWeapon(player: Player, id: string): boolean
	local places = { player:FindFirstChild("Backpack"), player.Character }
	for _, place in places do
		if place then
			for _, child in place:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("WeaponId") == id then
					return true
				end
			end
		end
	end
	return false
end

local function giveTool(player: Player, id: string)
	local backpack = player:FindFirstChild("Backpack")
	local template = if templates then templates:FindFirstChild(id) else nil
	if backpack == nil or template == nil or hasWeapon(player, id) then
		if template == nil then
			warn(`[WeaponService] Нет шаблона ServerStorage.{TEMPLATES_FOLDER}.{id}`)
		end
		return
	end
	template:Clone().Parent = backpack
end

local function giveOwnedWeapons(player: Player)
	local data = DataService:get(player)
	if data == nil then
		return
	end
	for id in data.Equipment.Weapons do
		if Weapons[id] then
			giveTool(player, id)
		end
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local state = stateOf(player)
	table.clear(state.equippedAt)
	character.ChildAdded:Connect(function(child: Instance)
		local _, info = weaponOf(child)
		if info then
			state.equippedAt[child] = os.clock()
			if info.Scoped then
				addGlint(child)
			end
		end
	end)
	character.ChildRemoved:Connect(function(child: Instance)
		state.equippedAt[child] = nil
		removeGlint(child)
	end)
	-- defer: при возрождении Roblox пересоздаёт рюкзак сразу после CharacterAdded.
	task.defer(giveOwnedWeapons, player)
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Выдать игроку оружие навсегда (магазин, чат-команда). Возвращает true при успехе.
function WeaponService:giveWeapon(player: Player, id: string): boolean
	if Weapons[id] == nil or not DataService:isLoaded(player) then
		return false
	end
	DataService:update(player, "Equipment", function(equipment)
		if equipment.Weapons[id] == nil then
			equipment.Weapons[id] = 1
		end
		return equipment
	end)
	giveTool(player, id)
	return true
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function WeaponService:Init()
	templates = ServerStorage:FindFirstChild(TEMPLATES_FOLDER)
	if templates == nil then
		warn(`[WeaponService] Нет папки ServerStorage.{TEMPLATES_FOLDER} с оружием`)
	end
end

function WeaponService:Start()
	DataService:onLoaded(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			onCharacterAdded(player, character)
		end)
		local character = player.Character
		if character then
			onCharacterAdded(player, character)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		shooters[player] = nil
	end)

	NetService:on("Fire", {
		args = { Guard.vector3(2) },
		rate = 12, -- автомат стреляет ~8 раз в секунду, с запасом на пинг
		burst = 16,
	}, onFire)
end

return WeaponService
