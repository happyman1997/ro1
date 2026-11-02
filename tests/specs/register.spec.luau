--[[
	Касса и взлом разведчиком.

	Касса Tier 1 стоит на стойке у входа. Охранник видит точку (0, 3, 6.5) перед стойкой,
	поэтому в тестах «охрана не видит» охранник убирается со сцены.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local owner = world:addPlayer("Owner", 1)
	local thief = world:addPlayer("Thief", 2)
	world:advance(0.5)
	local plotModel = world:plot(1)
	local s = {
		Data = world:module(SERVICES .. "DataService"),
		Plot = world:module(SERVICES .. "PlotService"),
		Register = world:module(SERVICES .. "CashRegisterService"),
		Class = world:module(SERVICES .. "ClassService"),
	}
	local plot = s.Plot:getPlot(owner)
	local register = world:findTagged(plotModel:FindFirstChild("Restaurant"), "CashRegister")
	return owner, thief, plotModel, plot, register, s
end

local function becomeScout(world, thief, s)
	world:chat(thief, "/class Stealth")
	assert(s.Class:getClassId(thief) == "Stealth", "вор не стал разведчиком")
end

local function removeGuard(plotModel)
	plotModel:FindFirstChild("Restaurant"):FindFirstChild("Gunner", true):Destroy()
end

local function hackStates(world, player)
	local list = {}
	for _, args in world:received(player, "HackState") do
		table.insert(list, args[1] .. ":" .. tostring(args[2]))
	end
	return list
end

local function startHack(world, thief, register)
	world:moveTo(thief, register.Position + world.Vector3.new(0, -1, 2.2))
	world:trigger(thief, world:findPrompt(register, "Hack"))
end

return function(test)
	test(
		"разведчик взламывает кассу, когда его никто не видит",
		function(world, expect)
			local owner, thief, plotModel, plot, register, s = setup(world)
			removeGuard(plotModel)
			becomeScout(world, thief, s)
			s.Register:deposit(plot, 1200)
			world:moveTo(owner, world.Vector3.new(0, 3, 70))

			startHack(world, thief, register)
			expect.equal(
				hackStates(world, thief)[1],
				"Started:" .. tostring(world:received(thief, "HackState")[1][2]),
				"взлом начался"
			)
			world:advance(2.5)
			expect.truthy(
				world:hasNotification(owner, "Кто-то взламывает"),
				"владельцу пришла тревога"
			)
			world:advance(6)

			expect.equal(s.Data:get(thief).Cash, 900, "вор унёс 75% кассы")
			expect.near(s.Register:getCash(plot), 300, 0.01, "в кассе осталось 25%")
			expect.equal(s.Data:get(thief).Stats.Robberies, 1, "статистика вора")
			expect.equal(s.Data:get(owner).Stats.TimesRobbed, 1, "статистика владельца")
			expect.truthy(
				world:hasNotification(thief, "Касса взломана: +$900"),
				"уведомление вору"
			)
		end
	)

	test(
		"после кражи касса защищена от повторного взлома",
		function(world, expect)
			local owner, thief, plotModel, plot, register, s = setup(world)
			removeGuard(plotModel)
			becomeScout(world, thief, s)
			s.Register:deposit(plot, 1200)
			world:moveTo(owner, world.Vector3.new(0, 3, 70))
			startHack(world, thief, register)
			world:advance(9)
			s.Register:deposit(plot, 1200)
			startHack(world, thief, register)
			expect.truthy(
				world:hasNotification(thief, "Касса недавно взломана"),
				"повторный взлом отклонён"
			)
			expect.equal(
				#hackStates(world, thief),
				2,
				"новых взломов не началось (Started + Ended)"
			)
		end
	)

	test("взлом срывается, если вор достаёт оружие", function(world, expect)
		local owner, thief, plotModel, plot, register, s = setup(world)
		removeGuard(plotModel)
		becomeScout(world, thief, s)
		s.Register:deposit(plot, 1200)
		world:moveTo(owner, world.Vector3.new(0, 3, 70))
		startHack(world, thief, register)
		world:advance(1)
		world:equip(thief)
		world:advance(0.5)
		expect.truthy(
			world:hasNotification(thief, "Взлом сорван: вор достал оружие"),
			"взлом сорван"
		)
		expect.truthy(thief:GetAttribute("ExposedUntil"), "маскировка раскрыта")
		expect.equal(s.Data:get(thief).Cash, 0, "денег вор не получил")
	end)

	test("владелец рядом с кассой ловит вора", function(world, expect)
		local owner, thief, plotModel, plot, register, s = setup(world)
		removeGuard(plotModel)
		becomeScout(world, thief, s)
		s.Register:deposit(plot, 1200)
		world:moveTo(owner, register.Position + world.Vector3.new(-3, -1, 3))
		startHack(world, thief, register)
		world:advance(0.5)
		expect.truthy(world:hasNotification(thief, "владелец поймал вора"), "вор пойман")
		expect.truthy(thief:GetAttribute("ExposedUntil"), "маскировка раскрыта")
		expect.equal(s.Data:get(thief).Cash, 0, "денег вор не получил")
	end)

	test("не разведчик не может взламывать", function(world, expect)
		local _, thief, _, plot, register, s = setup(world)
		s.Register:deposit(plot, 1200)
		startHack(world, thief, register)
		expect.equal(#hackStates(world, thief), 0, "взлом не начался")
		expect.truthy(
			world:hasWarning("взлом кассы не разведчиком"),
			"анти-чит заметил"
		)
	end)

	test("взлом издалека отклоняется", function(world, expect)
		local _, thief, plotModel, plot, register, s = setup(world)
		becomeScout(world, thief, s)
		s.Register:deposit(plot, 1200)
		world:moveTo(thief, world:plotPoint(plotModel, 0, 3, 25))
		world:trigger(thief, world:findPrompt(register, "Hack"))
		expect.equal(#hackStates(world, thief), 0, "взлом не начался")
		expect.truthy(world:hasWarning("взлом кассы издалека"), "анти-чит заметил")
	end)

	test("охрана стреляет во взломщика, если видит его", function(world, expect)
		local owner, thief, plotModel, plot, register, s = setup(world)
		becomeScout(world, thief, s)
		s.Register:deposit(plot, 1200)
		world:moveTo(owner, world.Vector3.new(0, 3, 70))
		world:moveTo(thief, world:plotPoint(plotModel, 0, 3, 6.5))
		world:trigger(thief, world:findPrompt(register, "Hack"))
		expect.equal(#hackStates(world, thief), 1, "взлом начался")
		local before = world:humanoid(thief).Health
		world:advance(3)
		expect.less(world:humanoid(thief).Health, before, "охрана стреляет во взломщика")
	end)
	test(
		"кассу можно разбить: 40% высыпается, остальное сгорает, ресторан встаёт",
		function(world, expect)
			local owner, thief, plotModel, plot, register, s = setup(world)
			removeGuard(plotModel)
			world:chat(thief, "/class Demolition") -- урон по конструкциям ×3: 15 за выстрел
			s.Register:deposit(plot, 1200)
			world:moveTo(owner, world.Vector3.new(0, 3, 70))
			world:moveTo(thief, world:plotPoint(plotModel, 0, 3, 9))
			world:equip(thief, "Pistol")
			world:advance(0.5)
			for _ = 1, 20 do
				world:fireServer(thief, "Fire", world:aimAt(thief, register.Position))
				world:advance(0.31)
			end
			expect.equal(register:GetAttribute("Broken"), true, "касса разбита (300 прочности)")
			expect.equal(s.Register:getCash(plot), 0, "в кассе ничего не осталось")
			local drops = world.workspace:FindFirstChild("CashDrops"):GetChildren()
			expect.equal(#drops, 1, "высыпалась одна пачка")
			expect.equal(drops[1]:GetAttribute("Amount"), 480, "40% от $1200")
			expect.equal(world:findPrompt(register, "Collect"), nil, "разбитую кассу не забрать")
			expect.equal(world:findPrompt(register, "Hack"), nil, "и не взломать")
			expect.truthy(
				world:hasNotification(owner, "Вашу кассу разбили"),
				"владельцу сообщили"
			)
			world:advance(2.5)
			expect.equal(plotModel:GetAttribute("Operational"), false, "ресторан стоит")
			s.Register:deposit(plot, 100)
			expect.equal(
				s.Register:getCash(plot),
				0,
				"разбитая касса не принимает выручку"
			)
		end
	)

	test("после ремонта касса снова работает", function(world, expect)
		local owner, thief, plotModel, plot, register, s = setup(world)
		removeGuard(plotModel)
		register:SetAttribute("Health", 1)
		world:moveTo(thief, world:plotPoint(plotModel, 0, 3, 9))
		world:equip(thief, "Pistol")
		world:advance(0.5)
		world:fireServer(thief, "Fire", world:aimAt(thief, register.Position))
		expect.equal(register:GetAttribute("Broken"), true, "касса разбита")
		world:moveTo(thief, world.Vector3.new(0, 3, 70))
		world:advance(25) -- бой закончился
		world:chat(owner, "/cash 500")
		world:chat(owner, "/repair")
		local newRegister = world:findTagged(plotModel:FindFirstChild("Restaurant"), "CashRegister")
		expect.truthy(newRegister ~= register, "новая касса после ремонта")
		expect.truthy(world:findPrompt(newRegister, "Collect"), "подсказка сбора вернулась")
		s.Register:deposit(plot, 100)
		expect.equal(s.Register:getCash(plot), 100, "касса принимает выручку")
	end)
end
