--[[
	Подсказки новичку: приветствие, «заберите выручку», «хватает на улучшение»,
	«почините ресторан»; одна за раз, каждая один раз, исчезают сами;
	выключатель во вкладке «Настройки» сохраняется на сервере.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local player = world:addPlayer("Player", 1)
	world:advance(0.5)
	world:startClient(player)
	world:advance(1.1)
	return player
end

local function tipText(world, player): string?
	local banner = world:gui(player, "TipBanner")
	return if banner.Visible then world:gui(player, "TipLabel").Text else nil
end

local function has(text: string?, fragment: string): boolean
	return text ~= nil and string.find(text, fragment, 1, true) ~= nil
end

-- Закрыть текущую подсказку и дождаться следующей проверки после паузы.
local function closeAndWait(world, player)
	world:click(world:gui(player, "TipClose"))
	world:advance(4.1)
end

return function(test)
	test(
		"приветствие, затем «заберите выручку» при полкассы",
		function(world, expect)
			local player = setup(world)
			expect.truthy(has(tipText(world, player), "Это ваш ресторан"), "приветствие")
			world:click(world:gui(player, "TipClose"))
			expect.equal(tipText(world, player), nil, "закрылась по кнопке")

			local plots = world:module(SERVICES .. "PlotService")
			world:module(SERVICES .. "CashRegisterService"):deposit(plots:getPlot(player), 600)
			world:advance(4.1)
			expect.truthy(has(tipText(world, player), "нажмите E"), "подсказка про кассу")
		end
	)

	test("хватает денег — подсказка про улучшение", function(world, expect)
		local player = setup(world)
		world:chat(player, "/cash 6000")
		closeAndWait(world, player)
		expect.truthy(
			has(tipText(world, player), "«Улучшить»"),
			"подсказка про улучшение"
		)
	end)

	test("ресторан стоит — подсказка про ремонт", function(world, expect)
		local player = setup(world)
		world:chat(player, "/break")
		closeAndWait(world, player)
		expect.truthy(has(tipText(world, player), "«Починить»"), "подсказка про ремонт")
	end)

	test("кафе без охраны — подсказка про наём", function(world, expect)
		local player = setup(world)
		world:chat(player, "/cash 6000")
		world:chat(player, "/upgrade")
		closeAndWait(world, player)
		expect.truthy(
			has(tipText(world, player), "Наймите охрану"),
			"подсказка про охрану"
		)
	end)

	test("между подсказками пауза 3 секунды", function(world, expect)
		local player = setup(world)
		world:chat(player, "/cash 6000")
		world:click(world:gui(player, "TipClose"))
		world:advance(2)
		expect.equal(tipText(world, player), nil, "сразу следующая не выскакивает")
		world:advance(2.1)
		expect.truthy(
			has(tipText(world, player), "«Улучшить»"),
			"после паузы — следующая"
		)
	end)

	test(
		"подсказка исчезает сама и больше не повторяется",
		function(world, expect)
			local player = setup(world)
			expect.truthy(has(tipText(world, player), "Это ваш ресторан"), "приветствие")
			world:advance(12.5)
			expect.equal(tipText(world, player), nil, "исчезла через 12 секунд")
			world:advance(20)
			expect.equal(tipText(world, player), nil, "не показалась снова")
			world:advance(30)
			expect.truthy(
				has(tipText(world, player), "«Класс»"),
				"через минуту — про классы"
			)
		end
	)

	test(
		"выключатель в настройках: подсказки пропадают, выбор сохранён",
		function(world, expect)
			local player = setup(world)
			world:click(world:gui(player, "SettingsTab"))
			expect.equal(
				world:gui(player, "TipsToggle").Text,
				"Включены",
				"по умолчанию включены"
			)
			world:click(world:gui(player, "TipsToggle"))
			world:advance(0.1)
			local data = world:module(SERVICES .. "DataService")
			expect.equal(data:get(player).Settings.ShowTips, false, "сервер сохранил выбор")
			expect.equal(
				world:gui(player, "TipsToggle").Text,
				"Выключены",
				"кнопка показывает новое значение"
			)
			expect.equal(tipText(world, player), nil, "текущая подсказка скрыта")

			world:chat(player, "/cash 6000")
			world:advance(10)
			expect.equal(tipText(world, player), nil, "новых подсказок нет")
		end
	)
end
