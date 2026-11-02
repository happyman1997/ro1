--[[
	NPC-клиенты: приходят к стойке и уходят, не больше MaxCustomers, уходят из
	сломанного ресторана, убегают при атаке; убийство клиента ничего не даёт и
	ничего не ломает, пули и взрывы их задевают, но не свой ресторан.

	Tier 1: места у стойки — точки CustomerOrder перед стойкой (снаружи ларька,
	под козырьком). В симуляторе Tween ставит детали сразу в конец отрезка.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local owner = world:addPlayer("Owner", 1)
	world:advance(0.5)
	local plots = world:module(SERVICES .. "PlotService")
	return owner, plots:getPlot(owner), world:module(SERVICES .. "CustomerService"), plots
end

-- Подождать, пока какой-нибудь клиент встанет у стойки.
local function waitForOrdering(world, customers, plot)
	for _ = 1, 80 do
		for _, model in customers:getCustomers(plot) do
			if customers:getState(model) == "Ordering" then
				return model
			end
		end
		world:advance(0.25)
	end
	error("за 20 секунд ни один клиент не дошёл до стойки")
end

-- Места у стойки (детали с тегом CustomerOrder).
local function orderSpots(world, plotModel)
	local CollectionService = world.game:GetService("CollectionService")
	local list = {}
	for _, descendant in plotModel:FindFirstChild("Restaurant"):GetDescendants() do
		if CollectionService:HasTag(descendant, "CustomerOrder") then
			table.insert(list, descendant)
		end
	end
	return list
end

return function(test)
	test("клиент приходит к стойке, стоит и уходит", function(world, expect)
		local _, plot, customers = setup(world)
		local model = waitForOrdering(world, customers, plot)
		expect.truthy(
			model:IsDescendantOf(plot.model:FindFirstChild("Customers")),
			"клиенты в папке участка"
		)

		local torso = model:FindFirstChild("Torso").Position
		local atSpot = false
		for _, spot in orderSpots(world, plot.model) do
			if math.abs(spot.Position.X - torso.X) < 0.05 and math.abs(spot.Position.Z - torso.Z) < 0.05 then
				atSpot = true
			end
		end
		expect.truthy(atSpot, "стоит на месте у стойки")

		local sawLeaving = false
		for _ = 1, 80 do
			if customers:getState(model) == "Leaving" then
				sawLeaving = true
			end
			if model.Parent == nil then
				break
			end
			world:advance(0.25)
		end
		expect.truthy(sawLeaving, "постоял и пошёл к выходу")
		expect.equal(model.Parent, nil, "дошёл до выхода и исчез")
	end)

	test(
		"клиентов не больше MaxCustomers уровня, даже если мест больше",
		function(world, expect)
			local _, plot, customers = setup(world)
			expect.equal(
				#orderSpots(world, plot.model),
				2,
				"в ларьке (Tier 1) два места у стойки"
			)
			-- В модели из Studio мест может быть больше, чем MaxCustomers: лимит всё равно действует.
			local spot = orderSpots(world, plot.model)[1]
			for index = 1, 3 do
				local extra = spot:Clone()
				extra.Name = "Extra" .. index
				extra.CFrame = spot.CFrame + world.Vector3.new(0, 0, 1.5 * index)
				extra.Parent = spot.Parent
			end
			local most = 0
			for _ = 1, 240 do
				world:advance(0.5)
				most = math.max(most, #customers:getCustomers(plot))
			end
			expect.equal(
				most,
				2,
				"одновременно не больше двух (MaxCustomers), и двое бывает"
			)
		end
	)

	test(
		"сломанный ресторан: клиенты уходят, новые не приходят",
		function(world, expect)
			local owner, plot, customers = setup(world)
			waitForOrdering(world, customers, plot)
			world:chat(owner, "/break")
			world:advance(15)
			expect.equal(plot.model:GetAttribute("Operational"), false, "ресторан стоит")
			expect.equal(#customers:getCustomers(plot), 0, "все ушли")
			world:advance(15)
			expect.equal(#customers:getCustomers(plot), 0, "новые не пришли")
		end
	)

	test(
		"при атаке клиенты убегают бегом, новые не приходят",
		function(world, expect)
			local _, plot, customers, plots = setup(world)
			local model = waitForOrdering(world, customers, plot)
			plots:markCombat(plot)
			world:advance(0.3)
			expect.equal(customers:getState(model), "Leaving", "бросил заказ и уходит")
			world:advance(0.8)
			expect.equal(model.Parent, nil, "убежал бегом (пешком дошёл бы позже)")
			world:advance(10)
			expect.equal(#customers:getCustomers(plot), 0, "пока идёт бой, никто не приходит")
		end
	)

	test(
		"убийство клиента: $0, без тревоги, доход идёт, пуля летит дальше",
		function(world, expect)
			local owner, plot, customers, plots = setup(world)
			local shooter = world:addPlayer("Shooter", 2)
			local behind = world:addPlayer("Behind", 3)
			world:advance(0.5)
			local data = world:module(SERVICES .. "DataService")
			world:chat(shooter, "/weapon Sniper")

			local model = waitForOrdering(world, customers, plot)
			local torso = model:FindFirstChild("Torso")
			-- Стрелок сбоку вдоль стойки, за пределами территории (охрана его не трогает).
			world:moveTo(shooter, torso.Position + world.Vector3.new(36, 2.6, 0))
			world:equip(shooter, "Sniper")
			world:advance(1.3) -- время доставания снайперской винтовки
			local direction = world:aimAt(shooter, torso.Position)
			-- Третий игрок стоит на линии огня за клиентом.
			world:moveTo(behind, torso.Position + direction * 8)
			local cashBefore = data:get(shooter).Cash

			world:fireServer(shooter, "Fire", direction)
			expect.equal(customers:getState(model), "Dead", "клиент убит")
			expect.equal(torso.CanQuery, false, "труп больше не ловит пули")
			expect.less(
				world:humanoid(behind).Health,
				world:humanoid(behind).MaxHealth,
				"пуля прошла сквозь клиента: живым щитом он не служит"
			)
			expect.equal(data:get(shooter).Cash, cashBefore, "за убийство клиента $0")
			expect.equal(world:hasNotification(owner, "Тревога"), false, "тревоги нет")
			expect.equal(
				plots:isInCombat(plot),
				false,
				"участок не «в бою»: ремонт и улучшение не заблокированы"
			)

			world:advance(3.5)
			expect.equal(model.Parent, nil, "тело убрано через 3 секунды")
			expect.equal(plot.model:GetAttribute("Operational"), true, "ресторан работает дальше")
		end
	)

	test(
		"своих клиентов владелец не убивает ни пулей, ни зарядом",
		function(world, expect)
			local owner, plot, customers = setup(world)
			world:chat(owner, "/class Demolition")
			local model = waitForOrdering(world, customers, plot)
			local torso = model:FindFirstChild("Torso")
			world:moveTo(owner, torso.Position + world.Vector3.new(5, 1.1, 3))
			world:equip(owner, "Pistol")
			world:advance(0.5)
			world:fireServer(owner, "Fire", world:aimAt(owner, torso.Position))
			expect.equal(
				customers:getState(model),
				"Ordering",
				"пуля владельца клиента не задела"
			)
			world:fireServer(owner, "UseAbility", world.Vector3.new(torso.Position.X + 2, 0.1, torso.Position.Z + 2))
			world:advance(2.1)
			expect.equal(
				customers:getState(model),
				"Ordering",
				"заряд владельца клиента не задел"
			)
		end
	)

	test(
		"охрана видит сквозь клиента: живым щитом не спрятаться",
		function(world, expect)
			local _, plot, customers = setup(world)
			local hider = world:addPlayer("Hider", 2)
			world:advance(0.5)
			local LineOfSight = world:module("ServerScriptService.Server.Modules.LineOfSight")
			local model = waitForOrdering(world, customers, plot)
			local torso = model:FindFirstChild("Torso").Position
			-- Игрок прячется за клиентом: оба луча (к корпусу и к голове) идут сквозь клиента.
			world:moveTo(hider, torso + world.Vector3.new(-4, 0, 0))
			local eye = torso + world.Vector3.new(10, 0.75, 0)
			expect.truthy(LineOfSight.canSee(eye, hider.Character, {}), "видно сквозь клиента")
		end
	)

	test("взрыв заряда задевает клиентов", function(world, expect)
		local _, plot, customers = setup(world)
		local demo = world:addPlayer("Demo", 2)
		world:advance(0.5)
		world:chat(demo, "/class Demolition")
		local model = waitForOrdering(world, customers, plot)
		local torso = model:FindFirstChild("Torso").Position
		world:moveTo(demo, torso + world.Vector3.new(5, 1.1, 3))
		world:fireServer(demo, "UseAbility", world.Vector3.new(torso.X + 2, 0.1, torso.Z + 2))
		expect.truthy(world:hasNotification(demo, "установлен"), "заряд поставлен")
		world:advance(2.1)
		expect.equal(customers:getState(model), "Dead", "клиент погиб от взрыва")
	end)

	test("улучшение и уход владельца убирают клиентов", function(world, expect)
		local owner, plot, customers = setup(world)
		local model = waitForOrdering(world, customers, plot)
		world:chat(owner, "/cash 6000")
		world:chat(owner, "/upgrade")
		expect.equal(
			model.Parent,
			nil,
			"у новой модели свои точки: старые клиенты исчезли"
		)
		expect.equal(#orderSpots(world, plot.model), 3, "у кафе (Tier 2) три места у стойки")

		waitForOrdering(world, customers, plot)
		world:removePlayer(owner)
		expect.equal(
			#plot.model:FindFirstChild("Customers"):GetChildren(),
			0,
			"участок освобождён — клиентов нет"
		)
	end)
end
