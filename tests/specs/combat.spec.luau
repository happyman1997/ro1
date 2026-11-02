--[[
	Последствия боя: выпадение денег, подбор, исчезновение пачек, выход из боя.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function duel(world)
	local shooter = world:addPlayer("Shooter", 1)
	local victim = world:addPlayer("Victim", 2)
	world:advance(0.5)
	world:moveTo(shooter, world.Vector3.new(20, 3, 60))
	world:moveTo(victim, world.Vector3.new(20, 3, 70))
	world:chat(victim, "/cash 1000")
	world:equip(shooter, "Pistol")
	world:advance(0.5)
	return shooter, victim, world:module(SERVICES .. "DataService")
end

local function shoot(world, shooter, victim)
	world:fireServer(shooter, "Fire", world:aimAt(shooter, victim.Character.HumanoidRootPart.Position))
end

local function drops(world)
	return world.workspace:FindFirstChild("CashDrops"):GetChildren()
end

return function(test)
	test(
		"убитый игроком теряет 20% кошелька, пачку можно подобрать",
		function(world, expect)
			local shooter, victim, data = duel(world)
			world:humanoid(victim).Health = 10
			shoot(world, shooter, victim)
			expect.equal(world:humanoid(victim).Health, 0, "жертва погибла")
			expect.equal(data:get(victim).Cash, 800, "из кошелька выпало 20%")
			local list = drops(world)
			expect.equal(#list, 1, "на месте гибели лежит пачка")
			expect.equal(list[1]:GetAttribute("Amount"), 200, "в пачке $200")
			expect.truthy(world:hasNotification(victim, "выронили $200"), "жертве сообщили")
			expect.truthy(
				world:hasNotification(shooter, "Вы победили Victim"),
				"стрелку сообщили"
			)

			world:moveTo(shooter, list[1].Position + world.Vector3.new(0, 1, 2))
			world:trigger(shooter, list[1]:FindFirstChildWhichIsA("ProximityPrompt"))
			expect.equal(data:get(shooter).Cash, 200, "стрелок подобрал деньги")
			expect.equal(#drops(world), 0, "пачка исчезла")
		end
	)

	test("гибель без нападавшего — деньги не выпадают", function(world, expect)
		local _, victim, data = duel(world)
		world:humanoid(victim).Health = 0
		expect.equal(data:get(victim).Cash, 1000, "кошелёк цел")
		expect.equal(#drops(world), 0, "пачки нет")
	end)

	test("вор, убитый охраной, роняет деньги в ресторане", function(world, expect)
		world:addPlayer("Owner", 1)
		local thief = world:addPlayer("Thief", 2)
		world:advance(0.5)
		world:chat(thief, "/cash 1000")
		world:moveTo(thief, world:plotPoint(world:plot(1), 0, 3, 9))
		world:humanoid(thief).Health = 5
		world:equip(thief, "Pistol")
		world:advance(3)
		expect.equal(world:humanoid(thief).Health, 0, "охрана убила вора")
		expect.equal(world:module(SERVICES .. "DataService"):get(thief).Cash, 800, "вор выронил 20%")
		expect.equal(#drops(world), 1, "пачка лежит у ресторана")
	end)

	test("подобрать пачку издалека нельзя", function(world, expect)
		local shooter, victim, data = duel(world)
		world:humanoid(victim).Health = 10
		shoot(world, shooter, victim)
		local drop = drops(world)[1]
		world:moveTo(shooter, drop.Position + world.Vector3.new(0, 0, 40))
		world:trigger(shooter, drop:FindFirstChildWhichIsA("ProximityPrompt"))
		expect.equal(data:get(shooter).Cash, 0, "денег не дали")
		expect.equal(#drops(world), 1, "пачка на месте")
		expect.truthy(world:hasWarning("подбор денег издалека"), "анти-чит заметил")
	end)

	test("пачку забирает только первый", function(world, expect)
		local shooter, victim, data = duel(world)
		local third = world:addPlayer("Third", 3)
		world:humanoid(victim).Health = 10
		shoot(world, shooter, victim)
		local drop = drops(world)[1]
		local prompt = drop:FindFirstChildWhichIsA("ProximityPrompt")
		world:moveTo(shooter, drop.Position + world.Vector3.new(0, 1, 2))
		world:moveTo(third, drop.Position + world.Vector3.new(0, 1, -2))
		world:trigger(shooter, prompt)
		world:trigger(third, prompt)
		expect.equal(data:get(shooter).Cash + data:get(third).Cash, 200, "деньги не удвоились")
	end)

	test("пачка исчезает через 90 секунд", function(world, expect)
		local shooter, victim = duel(world)
		world:humanoid(victim).Health = 10
		shoot(world, shooter, victim)
		expect.equal(#drops(world), 1, "пачка появилась")
		world:advance(91)
		expect.equal(#drops(world), 0, "пачка исчезла")
	end)

	test(
		"выход из игры в бою: штраф, деньги остаются на месте",
		function(world, expect)
			local shooter, victim, data = duel(world)
			shoot(world, shooter, victim)
			expect.greater(world:humanoid(victim).Health, 0, "жертва жива, но ранена")
			world:removePlayer(victim)
			world:advance(1)
			expect.equal(#drops(world), 1, "деньги выпали на месте")
			expect.equal(drops(world)[1]:GetAttribute("Amount"), 200, "в пачке $200")
			local back = world:addPlayer("Victim", 2)
			expect.equal(data:get(back).Cash, 800, "штраф сохранился в данных")
		end
	)

	test("выход из игры вне боя — без штрафа", function(world, expect)
		local _, victim, data = duel(world)
		world:removePlayer(victim)
		world:advance(1)
		expect.equal(#drops(world), 0, "ничего не выпало")
		local back = world:addPlayer("Victim", 2)
		expect.equal(data:get(back).Cash, 1000, "кошелёк цел")
	end)
end
