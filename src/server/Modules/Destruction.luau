--!strict
--[[
	Destruction — общее для пуль и взрывов: урон по разрушаемым объектам и охране.

	Разрушаемое — деталь или модель с атрибутом:
	  MaxHealth     — ломается от пуль и взрывов (мебель, касса, доски, кирпич, стекло);
	  ArmoredHealth — ломается только от взрывов (монолит и стальные жалюзи Tier 3–4).
	Текущее здоровье — атрибут Health (для MaxHealth) или само ArmoredHealth.
	При нуле — атрибут Broken: мебель темнеет и останавливает ресторан,
	стены и стекло становятся проходимыми до ремонта.
]]

local CollectionService = game:GetService("CollectionService")

local Destruction = {}

-- Ближайший предок (или сам объект) с одним из тегов.
function Destruction.findTaggedAncestor(instance: Instance, tags: { string }): Instance?
	local node: Instance? = instance
	while node and node ~= workspace do
		for _, tag in tags do
			if CollectionService:HasTag(node, tag) then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

-- Разрушаемый объект, к которому относится деталь. explosive: учитывать бронированные.
function Destruction.find(instance: Instance, explosive: boolean): Instance?
	local node: Instance? = instance
	while node and node ~= workspace do
		if typeof(node:GetAttribute("MaxHealth")) == "number" then
			return node
		end
		if explosive and typeof(node:GetAttribute("ArmoredHealth")) == "number" then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function setPassable(target: Instance)
	local items = { target }
	for _, descendant in target:GetDescendants() do
		table.insert(items, descendant)
	end
	for _, item in items do
		if item:IsA("BasePart") then
			local part = item :: BasePart
			part.Transparency = 1
			part.CanCollide = false
			part.CanQuery = false
		end
	end
end

function Destruction.breakObject(target: Instance)
	target:SetAttribute("Broken", true)
	if CollectionService:HasTag(target, "Furniture") then
		-- Мебель остаётся на месте, но потемневшая: ресторан стоит, пока не починят.
		if target:IsA("BasePart") then
			local part = target :: BasePart
			part.Color = Color3.fromRGB(45, 45, 45)
		end
	else
		setPassable(target) -- стена или стекло разрушены: проход открыт
	end
end

-- Нанести урон разрушаемому объекту. Возвращает true, если урон прошёл.
function Destruction.damage(target: Instance, amount: number, explosive: boolean): boolean
	if amount <= 0 then
		return false
	end
	if explosive then
		local armored = target:GetAttribute("ArmoredHealth")
		if typeof(armored) == "number" then
			if armored <= 0 then
				return false
			end
			local left = math.max(0, armored - amount)
			target:SetAttribute("ArmoredHealth", left)
			if left <= 0 then
				Destruction.breakObject(target)
			end
			return true
		end
	end
	local maxHealth = target:GetAttribute("MaxHealth")
	if typeof(maxHealth) ~= "number" then
		return false
	end
	local health = target:GetAttribute("Health")
	local current = if typeof(health) == "number" then health else maxHealth
	if current <= 0 then
		return false
	end
	local left = math.max(0, current - amount)
	target:SetAttribute("Health", left)
	if left <= 0 then
		Destruction.breakObject(target)
	end
	return true
end

-- Урон охраннику (Humanoid) или турели (атрибут Health).
function Destruction.damageDefender(defender: Instance, amount: number)
	local humanoid = defender:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if humanoid.Health > 0 then
			humanoid:TakeDamage(amount)
		end
		return
	end
	local health = defender:GetAttribute("Health")
	if typeof(health) == "number" and health > 0 then
		defender:SetAttribute("Health", math.max(0, health - amount))
	end
end

return table.freeze(Destruction)
