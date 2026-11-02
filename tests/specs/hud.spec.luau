--[[
	Интерфейс игрока (HudController): деньги и уровень, улучшение, ремонт,
	панели охраны, магазина и классов. Кнопки нажимаются как у настоящего игрока.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local player = world:addPlayer("Player", 1)
	world:advance(0.5)
	world:startClient(player)
	return player, world:module(SERVICES .. "DataService")
end

return function(test)
	test(
		"показывает деньги, уровень и состояние ресторана",
		function(world, expect)
			local player = setup(world)
			world:chat(player, "/cash 1000000") -- /cash даёт не больше миллиона за раз
			world:chat(player, "/cash 234567")
			expect.equal(
				world:gui(player, "CashLabel").Text,
				"$1 234 567",
				"деньги с разделителями"
			)
			expect.equal(
				world:gui(player, "TierLabel").Text,
				"Деревянный ларёк · уровень 1",
				"уровень"
			)
			expect.equal(
				world:gui(player, "StatusLabel").Text,
				"Ресторан работает",
				"состояние"
			)
			expect.equal(
				world:gui(player, "UpgradeButton").Text,
				"Улучшить — $6 000",
				"цена улучшения"
			)
			expect.equal(world:gui(player, "RepairButton").Visible, false, "кнопки ремонта нет")
		end
	)

	test("кнопка «Улучшить» улучшает ресторан", function(world, expect)
		local player = setup(world)
		world:chat(player, "/cash 6000")
		world:click(world:gui(player, "UpgradeButton"))
		expect.equal(world:plot(1):GetAttribute("Tier"), 2, "уровень 2")
		expect.equal(
			world:gui(player, "TierLabel").Text,
			"Кирпичное кафе · уровень 2",
			"надпись обновилась"
		)
		expect.equal(world:gui(player, "CashLabel").Text, "$0", "деньги списаны")
	end)

	test(
		"кнопка «Починить» появляется при поломке и чинит",
		function(world, expect)
			local player = setup(world)
			world:chat(player, "/break")
			world:advance(2.5)
			local repair = world:gui(player, "RepairButton")
			expect.equal(repair.Visible, true, "кнопка ремонта появилась")
			expect.equal(
				world:gui(player, "StatusLabel").Text,
				"Ресторан стоит — нужен ремонт",
				"состояние"
			)
			world:chat(player, "/cash 500")
			world:click(repair)
			expect.equal(world:plot(1):GetAttribute("Operational"), true, "ресторан работает")
			expect.equal(repair.Visible, false, "кнопка ремонта скрылась")
		end
	)

	test("панель охраны: нанять и уволить", function(world, expect)
		local player, data = setup(world)
		world:chat(player, "/cash 1500")
		world:click(world:gui(player, "DefenseTab"))
		expect.equal(world:gui(player, "DefensePanel").Visible, true, "панель открыта")
		local hire = world:gui(player, "Hire_Door1_Bouncer")
		expect.truthy(hire, "кнопка найма вышибалы")
		expect.equal(hire.Text, "Вышибала $1 500", "цена на кнопке")
		world:click(hire)
		expect.truthy(world:plot(1).Defense:FindFirstChild("Bouncer_Door1"), "вышибала нанят")
		local dismiss = world:gui(player, "Dismiss_Door1")
		expect.truthy(dismiss, "панель обновилась: кнопка увольнения")
		world:click(dismiss)
		expect.equal(#world:plot(1).Defense:GetChildren(), 0, "вышибала уволен")
		expect.equal(data:get(player).Cash, 750, "возвращена половина")
	end)

	test("магазин: купить автомат", function(world, expect)
		local player = setup(world)
		world:chat(player, "/cash 8000")
		world:click(world:gui(player, "ShopTab"))
		local buy = world:gui(player, "Buy_Rifle")
		expect.equal(buy.Text, "Купить $8 000", "цена")
		world:click(buy)
		expect.truthy(player.Backpack:FindFirstChild("Rifle"), "автомат в рюкзаке")
		expect.equal(world:gui(player, "Buy_Rifle").Text, "Куплено", "кнопка обновилась")
		expect.equal(
			world:gui(player, "Buy_Pistol"),
			nil,
			"бесплатный пистолет не продаётся"
		)
	end)

	test("выбор класса", function(world, expect)
		local player = setup(world)
		world:click(world:gui(player, "ClassTab"))
		expect.equal(
			world:gui(player, "Class_Assault").Text,
			"Выбран",
			"текущий класс отмечен"
		)
		world:click(world:gui(player, "Class_Tank"))
		expect.equal(world:module(SERVICES .. "ClassService"):getClassId(player), "Tank", "класс сменился")
		expect.equal(world:gui(player, "Class_Tank").Text, "Выбран", "панель обновилась")
	end)

	test("открыта только одна панель", function(world, expect)
		local player = setup(world)
		world:click(world:gui(player, "ShopTab"))
		world:click(world:gui(player, "ClassTab"))
		expect.equal(world:gui(player, "ShopPanel").Visible, false, "магазин закрылся")
		expect.equal(world:gui(player, "ClassPanel").Visible, true, "классы открыты")
		world:click(world:gui(player, "ClassPanel"):FindFirstChild("CloseButton"))
		expect.equal(world:gui(player, "ClassPanel").Visible, false, "закрыта крестиком")
	end)
end
