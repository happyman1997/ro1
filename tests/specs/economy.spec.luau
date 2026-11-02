--[[
	Экономика ресторана: участок, доход, касса, улучшение, поломка и ремонт.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function services(world)
	return {
		Data = world:module(SERVICES .. "DataService"),
		Plot = world:module(SERVICES .. "PlotService"),
		Register = world:module(SERVICES .. "CashRegisterService"),
	}
end

local function registerOf(world, plotModel)
	return world:findTagged(plotModel:FindFirstChild("Restaurant"), "CashRegister")
end

return function(test)
	test("игрок получает участок и ресторан 1 уровня", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		world:advance(1)

		local plot = world:plot(1)
		expect.equal(plot:GetAttribute("OwnerUserId"), 1, "владелец участка")
		expect.equal(plot:GetAttribute("Tier"), 1, "уровень")
		expect.truthy(plot:FindFirstChild("Restaurant"), "модель ресторана на участке")
		local distance = (owner.Character.HumanoidRootPart.Position - plot:FindFirstChild("Spawn").Position).Magnitude
		expect.less(distance, 5, "игрок появился у своей точки появления")
		expect.truthy(owner:FindFirstChild("leaderstats"), "таблица игроков")
	end)

	test("второй игрок получает второй участок", function(world, expect)
		world:addPlayer("Owner", 1)
		world:addPlayer("Second", 2)
		world:advance(0.5)
		expect.equal(world:plot(2):GetAttribute("OwnerUserId"), 2, "владелец второго участка")
	end)

	test(
		"выручка копится в кассе и упирается в лимит уровня",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local s = services(world)
			local plot = s.Plot:getPlot(owner)
			world:advance(10.5)
			expect.near(
				s.Register:getCash(plot),
				40,
				0.01,
				"выручка за 10 с (4 $/с, начисление раз в 2 с)"
			)
			world:advance(1000)
			expect.equal(s.Register:getCash(plot), 1200, "касса упирается в лимит Tier 1")
			expect.equal(registerOf(world, world:plot(1)):GetAttribute("Cash"), 1200, "витрина кассы")
		end
	)

	test("владелец забирает выручку", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local s = services(world)
		local plot = s.Plot:getPlot(owner)
		world:advance(10.5)
		local register = registerOf(world, world:plot(1))
		world:moveTo(owner, register.Position + world.Vector3.new(0, -1, 2.5))
		world:trigger(owner, world:findPrompt(register, "Collect"))

		expect.equal(s.Data:get(owner).Cash, 40, "деньги на кошельке")
		expect.equal(s.Register:getCash(plot), 0, "касса пуста")
		expect.equal(owner.leaderstats.Cash.Value, 40, "таблица игроков")
		expect.truthy(world:hasNotification(owner, "Выручка: +$40"), "уведомление")
	end)

	test("чужой игрок не может забрать выручку", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local stranger = world:addPlayer("Stranger", 2)
		local s = services(world)
		local plot = s.Plot:getPlot(owner)
		world:advance(10.5)
		local register = registerOf(world, world:plot(1))
		world:moveTo(stranger, register.Position + world.Vector3.new(0, -1, 2.5))
		world:trigger(stranger, world:findPrompt(register, "Collect"))

		expect.near(s.Register:getCash(plot), 40, 0.01, "касса не тронута")
		expect.equal(s.Data:get(stranger).Cash, 0, "чужой ничего не получил")
		expect.truthy(
			world:hasWarning("попытка забрать чужую кассу"),
			"анти-чит заметил"
		)
	end)

	test("сбор выручки издалека отклоняется", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local s = services(world)
		local plot = s.Plot:getPlot(owner)
		world:advance(10.5)
		-- Владелец стоит у своей точки появления, в ~20 студах от кассы.
		world:trigger(owner, world:findPrompt(registerOf(world, world:plot(1)), "Collect"))
		expect.equal(s.Data:get(owner).Cash, 0, "деньги не зачислены")
		expect.near(s.Register:getCash(plot), 40, 0.01, "касса не тронута")
		expect.truthy(world:hasWarning("сбор кассы издалека"), "анти-чит заметил")
	end)

	test(
		"улучшение: без денег отказ, с деньгами меняется модель",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local s = services(world)
			local plot = world:plot(1)
			world:chat(owner, "/upgrade")
			expect.equal(plot:GetAttribute("Tier"), 1, "без денег уровень прежний")
			expect.truthy(
				world:hasNotification(owner, "Улучшение стоит $6000"),
				"сообщение о цене"
			)

			world:chat(owner, "/cash 6000")
			world:chat(owner, "/upgrade")
			expect.equal(plot:GetAttribute("Tier"), 2, "уровень 2")
			expect.equal(s.Data:get(owner).Cash, 0, "деньги списаны")
			expect.equal(s.Data:get(owner).Restaurant.Tier, 2, "уровень сохранён в данных")
			local front = plot:FindFirstChild("Restaurant"):FindFirstChild("FrontLeft", true)
			expect.truthy(front, "модель кафе со стеклянной витриной")
			expect.equal(
				front:GetAttribute("SeeThrough"),
				true,
				"стекло прозрачно для взгляда охраны"
			)
		end
	)

	test(
		"поломка останавливает доход, ремонт возвращает",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local s = services(world)
			local plot = s.Plot:getPlot(owner)
			local plotModel = world:plot(1)
			world:chat(owner, "/break")
			world:advance(2.5)
			expect.equal(plotModel:GetAttribute("Operational"), false, "ресторан остановлен")
			expect.equal(
				s.Data:get(owner).Restaurant.NeedsRepair,
				true,
				"поломка сохранена в данных"
			)
			expect.truthy(
				world:hasNotification(owner, "Ресторан остановлен"),
				"уведомление владельцу"
			)

			local stopped = s.Register:getCash(plot)
			world:advance(10)
			expect.equal(s.Register:getCash(plot), stopped, "дохода нет")

			world:chat(owner, "/repair")
			expect.truthy(
				world:hasNotification(owner, "Ремонт стоит $150"),
				"без денег — отказ"
			)
			world:chat(owner, "/cash 500")
			world:chat(owner, "/repair")
			expect.equal(plotModel:GetAttribute("Operational"), true, "ресторан снова работает")
			expect.equal(s.Data:get(owner).Restaurant.NeedsRepair, false, "флаг поломки снят")
			expect.equal(s.Data:get(owner).Cash, 350, "ремонт оплачен")
			world:advance(4.5)
			expect.greater(s.Register:getCash(plot), stopped, "доход возобновился")
		end
	)

	test("перезаход не чинит ресторан бесплатно", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		world:chat(owner, "/break")
		world:advance(2.5)
		world:removePlayer(owner)
		world:advance(1)

		local again = world:addPlayer("Owner", 1)
		world:advance(2.5)
		expect.equal(
			world:plot(1):GetAttribute("Operational"),
			false,
			"после перезахода ресторан всё ещё сломан"
		)
		expect.truthy(
			world:hasNotification(again, "всё ещё сломан"),
			"напоминание о ремонте"
		)
	end)
end
