--!strict
--[[
	LineOfSight — «видит ли» и «может ли попасть» с учётом материалов здания.

	Атрибуты на деталях здания (ставятся в моделях уровней):
		SeeThrough = true   — сквозь деталь видно (стекло, решётка, сетка)
		ShootThrough = true — сквозь деталь проходят пули (тонкие доски ларька)

	Примеры по уровням ресторана:
		Tier 1, доски:          SeeThrough = false, ShootThrough = true
		Tier 2, обычное стекло: SeeThrough = true,  ShootThrough = true
		Tier 3, бронестекло:    SeeThrough = true,  ShootThrough не ставится
		                        (охрана видит, но не простреливает)
		Монолит, жалюзи:        ничего не ставится — глухая преграда

	Детали с CanQuery = false лучи не замечают вовсе (декор, невидимые зоны).
	Все проверки — только на сервере: удаление стен у себя на клиенте
	(локальный «wallhack») на них не влияет.
]]

local MAX_PASSES = 8 -- сколько «прозрачных» деталей подряд может пройти луч

local LineOfSight = {}

-- Точки прицеливания: корпус и голова.
local function targetPoints(character: Model): { Vector3 }
	local points = {}
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		table.insert(points, root.Position)
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		table.insert(points, head.Position)
	end
	return points
end

-- Луч от origin к target. Детали с атрибутом passAttribute пропускаются.
-- Возвращает (дошёл ли луч до персонажа, точка попадания или преграды).
local function trace(
	origin: Vector3,
	target: Vector3,
	character: Model,
	ignore: { Instance },
	passAttribute: string
): (boolean, Vector3)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local direction = target - origin
	for _ = 1, MAX_PASSES do
		local result = workspace:Raycast(origin, direction, params)
		if result == nil then
			return true, target
		end
		local hit = result.Instance
		if hit:IsDescendantOf(character) then
			return true, result.Position
		end
		if hit:GetAttribute(passAttribute) ~= true then
			return false, result.Position
		end
		params:AddToFilter(hit)
	end
	return false, target
end

-- Видно ли персонажа из точки origin (хотя бы корпус или голову).
function LineOfSight.canSee(origin: Vector3, character: Model, ignore: { Instance }): boolean
	for _, point in targetPoints(character) do
		local visible = trace(origin, point, character, ignore, "SeeThrough")
		if visible then
			return true
		end
	end
	return false
end

-- Есть ли линия огня до персонажа. Возвращает (можно ли попасть, точка попадания или преграды).
function LineOfSight.canShoot(origin: Vector3, character: Model, ignore: { Instance }): (boolean, Vector3)
	local blockedAt = origin
	for _, point in targetPoints(character) do
		local clear, position = trace(origin, point, character, ignore, "ShootThrough")
		if clear then
			return true, position
		end
		blockedAt = position
	end
	return false, blockedAt
end

return table.freeze(LineOfSight)
