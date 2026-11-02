--!strict
--[[
	AbilityService — способности классов (Config/Abilities): Подавление, Пробивной
	заряд, Щит, Метка охраны. Событие UseAbility(точка прицела?).

	ЗАЩИТА:
	• Какая способность доступна, решает класс игрока на сервере; перезарядку
	  считает сервер.
	• Заряд ставится только в пределах PlaceDistance от персонажа и только на
	  поверхность, которую сервер нашёл лучом от головы: «заминировать» стену
	  через полкарты нельзя.
	• Урон взрыва, радиус и время берутся из конфига; своё (свой ресторан и охрана)
	  взрыв не повреждает, как и пули.
	• Метка охраны отправляет клиенту только чужих защитников рядом с игроком.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Abilities = require(ReplicatedStorage.Shared.Config.Abilities)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local Guard = require(ReplicatedStorage.Shared.Guard)
local Destruction = require(script.Parent.Parent.Modules.Destruction)
local ClassService = require(script.Parent.ClassService)
local CombatService = require(script.Parent.CombatService)
local GuardAIService = require(script.Parent.GuardAIService)
local NetService = require(script.Parent.NetService)
local PartyService = require(script.Parent.PartyService)
local PlotService = require(script.Parent.PlotService)

local DEFENDER_TAGS = { "Guard", "Turret" }
local EFFECT_RADIUS = 300

type AbilityInfo = Abilities.AbilityInfo
type Handler = (player: Player, info: AbilityInfo, character: Model, root: BasePart, target: Vector3?) -> boolean

local AbilityService = {}

local cooldownUntil: { [Player]: number } = {}
local suppressUntil: { [Player]: number } = {}

local function reportAggression(plot: PlotService.Plot?, attacker: Player)
	if plot then
		GuardAIService:reportAggression(plot, attacker)
	end
end

-- Взрыв заряда: люди, охрана и разрушаемое в радиусе.
local function explode(attacker: Player, info: AbilityInfo, center: Vector3)
	local radius = info.Radius :: number
	local victims: { [Player]: boolean } = {}
	local defenders: { [Instance]: boolean } = {}
	local structures: { [Instance]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(center, radius) do
		local model = part:FindFirstAncestorOfClass("Model")
		local player = if model then Players:GetPlayerFromCharacter(model) else nil
		if player then
			victims[player] = true
		else
			local defender = Destruction.findTaggedAncestor(part, DEFENDER_TAGS)
			if defender then
				defenders[defender] = true
			else
				local target = Destruction.find(part, true)
				if target then
					structures[target] = true
				end
			end
		end
	end

	local damage = info.PlayerDamage :: number
	for victim in victims do
		if
			not PartyService:areAllies(attacker, victim)
			and CombatService:damagePlayer(victim, damage, attacker) > 0
		then
			local plot = PlotService:getPlot(victim)
			local _, _, root = CharacterUtil.getAlive(victim)
			if plot and root and PlotService:isInTerritory(plot, root.Position) then
				reportAggression(plot, attacker)
			end
		end
	end
	for defender in defenders do
		local plot = PlotService:getPlotFromInstance(defender)
		if not (plot and PlotService:isFriendly(plot, attacker)) then
			Destruction.damageDefender(defender, damage)
			reportAggression(plot, attacker)
		end
	end
	for target in structures do
		local plot = PlotService:getPlotFromInstance(target)
		if not (plot and PlotService:isFriendly(plot, attacker)) then
			if Destruction.damage(target, info.StructureDamage :: number, true) then
				reportAggression(plot, attacker)
			end
		end
	end
	NetService:fireNearby(center, EFFECT_RADIUS, nil, "ExplosionFx", center, radius)
end

-- Где стоит защитник: по его детали (корень, голова), а не по опоре модели —
-- у вложенной модели без PrimaryPart опора может быть неточной.
local function defenderPosition(defender: Model): Vector3
	for _, name in { "HumanoidRootPart", "Head" } do
		local part = defender:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return (part :: BasePart).Position
		end
	end
	return defender:GetPivot().Position
end

local handlers: { [string]: Handler } = {}

handlers.Suppress = function(player, info)
	suppressUntil[player] = os.clock() + (info.Duration :: number)
	NetService:notify(player, `{info.Name}: попадания по охране сбивают ей прицел`)
	return true
end

handlers.Shield = function(player, info)
	CombatService:addDamageReduction(player, info.Reduction :: number, info.Duration :: number)
	NetService:notify(player, `{info.Name}: урон снижен на {math.floor((info.Reduction :: number) * 100)}%`)
	return true
end

handlers.Mark = function(player, info, _character, root)
	local radius = info.Radius :: number
	local marked = {}
	for _, tag in DEFENDER_TAGS do
		for _, defender in CollectionService:GetTagged(tag) do
			if defender:IsDescendantOf(workspace) and defender:IsA("Model") then
				local plot = PlotService:getPlotFromInstance(defender)
				local position = defenderPosition(defender :: Model)
				if
					not (plot and PlotService:isFriendly(plot, player))
					and (position - root.Position).Magnitude <= radius
				then
					table.insert(marked, defender)
				end
			end
		end
	end
	NetService:fireClient(player, "MarkDefenders", marked, info.Duration)
	NetService:notify(player, `{info.Name}: замечено охраны — {#marked}`)
	return true
end

handlers.Breach = function(player, info, character, _root, target)
	local head = character:FindFirstChild("Head")
	if target == nil or head == nil or not head:IsA("BasePart") then
		return false
	end
	local origin = (head :: BasePart).Position
	local offset = target - origin
	local reach = (info.PlaceDistance :: number) + 2
	if offset.Magnitude > reach then
		NetService:notify(player, `{info.Name}: подойдите ближе (до {info.PlaceDistance} студов)`)
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(origin, offset.Unit * reach, params)
	local hitModel = if result then result.Instance:FindFirstAncestorOfClass("Model") else nil
	if result == nil or (hitModel and Players:GetPlayerFromCharacter(hitModel)) then
		NetService:notify(player, `{info.Name}: ставится только на стену или предмет`)
		return false
	end

	local charge = Instance.new("Part")
	charge.Name = "BreachCharge"
	charge.Size = Vector3.new(1, 1, 0.4)
	charge.Color = Color3.fromRGB(220, 40, 30)
	charge.Material = Enum.Material.Neon
	charge.Anchored = true
	charge.CanCollide = false
	charge.CanQuery = false
	charge.CanTouch = false
	charge.CFrame = CFrame.new(result.Position)
	charge.Parent = workspace
	task.delay(info.FuseTime :: number, function()
		charge:Destroy()
		explode(player, info, result.Position)
	end)
	NetService:notify(player, `{info.Name} установлен: взрыв через {info.FuseTime} с`)
	return true
end

-- Применить способность своего класса. Возвращает true, если сработала.
function AbilityService:use(player: Player, target: Vector3?): boolean
	local character, _, root = CharacterUtil.getAlive(player)
	if character == nil or root == nil then
		return false
	end
	local abilityId = ClassService:getClass(player).Ability
	local info = Abilities[abilityId]
	local handler = handlers[abilityId]
	if info == nil or handler == nil then
		return false
	end
	local now = os.clock()
	local remaining = (cooldownUntil[player] or 0) - now
	if remaining > 0 then
		NetService:notify(player, `{info.Name}: перезарядка {math.ceil(remaining)} с`)
		return false
	end
	if not handler(player, info, character, root, target) then
		return false
	end
	cooldownUntil[player] = now + info.Cooldown
	return true
end

-- Идёт ли у игрока подавление (WeaponService сбивает прицел охране при попадании).
function AbilityService:isSuppressing(player: Player): boolean
	return (suppressUntil[player] or 0) > os.clock()
end

function AbilityService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		cooldownUntil[player] = nil
		suppressUntil[player] = nil
	end)
	NetService:on("UseAbility", {
		args = { Guard.optional(Guard.vector3(100000)) },
		rate = 2,
		burst = 4,
	}, function(player: Player, target: Vector3?)
		AbilityService:use(player, target)
	end)
end

return AbilityService
