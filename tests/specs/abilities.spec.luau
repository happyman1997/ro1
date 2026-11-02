--[[
	Способности классов: Щит, Пробивной заряд, Подавление, Метка охраны;
	перезарядка, способность чужого класса, проверка аргументов, кнопка в интерфейсе.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function use(world, player, target)
	world:fireServer(player, "UseAbility", target)
end

local function duel(world)
	local shooter = world:addPlayer("Shooter", 1)
	local victim = world:addPlayer("Victim", 2)
	world:advance(0.5)
	return shooter, victim
end

return function(test)
	test("Танк: щит срезает 70% урона на 5 секунд", function(world, expect)
		local shooter, tank = duel(world)
		world:chat(tank, "/class Tank")
		world:moveTo(shooter, world.Vector3.new(20, 3, 60))
		world:moveTo(tank, world.Vector3.new(20, 3, 70))
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		use(world, tank)
		local before = world:humanoid(tank).Health
		world:fireServer(shooter, "Fire", world:aimAt(shooter, tank.Character.HumanoidRootPart.Position))
		expect.near(world:humanoid(tank).Health, before - 4.5, 0.01, "под щитом 30% урона")
		world:advance(5)
		before = world:humanoid(tank).Health
		world:fireServer(shooter, "Fire", world:aimAt(shooter, tank.Character.HumanoidRootPart.Position))
		expect.near(world:humanoid(tank).Health, before - 15, 0.01, "щит закончился")
	end)

	test("перезарядка способности считается на сервере", function(world, expect)
		local _, tank = duel(world)
		world:chat(tank, "/class Tank")
		use(world, tank)
		use(world, tank)
		expect.truthy(
			world:hasNotification(tank, "Щит: перезарядка"),
			"второй раз сразу — нельзя"
		)
		world:advance(25.1)
		use(world, tank)
		expect.equal(
			#world:received(tank, "Notify") > 0,
			true,
			"после перезарядки снова можно"
		)
	end)

	test(
		"Подрывник: заряд ломает бронированную стену Tier 3 за два взрыва",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local demo = world:addPlayer("Demo", 2)
			world:advance(0.5)
			world:chat(demo, "/class Demolition")
			world:chat(owner, "/cash 36000")
			world:chat(owner, "/upgrade")
			world:chat(owner, "/upgrade")
			local plot = world:plot(1)
			world:moveTo(owner, world.Vector3.new(0, 3, 90))
			local wall = plot:FindFirstChild("Restaurant"):FindFirstChild("LeftWall", true)
			world:moveTo(demo, world:plotPoint(plot, -17, 3, 0))
			local target = world:plotPoint(plot, -13.3, 3, 0)

			use(world, demo, target)
			world:advance(2.1)
			expect.equal(wall:GetAttribute("ArmoredHealth"), 300, "первый взрыв: 600 → 300")
			expect.equal(wall.CanCollide, true, "стена ещё стоит")

			world:advance(25)
			world:moveTo(demo, world:plotPoint(plot, -17, 3, 0))
			use(world, demo, target)
			world:advance(2.1)
			expect.equal(wall:GetAttribute("Broken"), true, "второй взрыв: стена разрушена")
			expect.equal(wall.CanCollide, false, "проход открыт")
		end
	)

	test("пули бронированную стену не берут", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local shooter = world:addPlayer("Shooter", 2)
		world:advance(0.5)
		world:chat(owner, "/cash 36000")
		world:chat(owner, "/upgrade")
		world:chat(owner, "/upgrade")
		local plot = world:plot(1)
		local wall = plot:FindFirstChild("Restaurant"):FindFirstChild("LeftWall", true)
		world:moveTo(shooter, world:plotPoint(plot, -17, 3, 0))
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		world:fireServer(shooter, "Fire", world:aimAt(shooter, world:plotPoint(plot, -13.3, 3, 0)))
		expect.equal(wall:GetAttribute("ArmoredHealth"), 600, "броня цела")
	end)

	test("заряд нельзя поставить издалека или в воздух", function(world, expect)
		local _, demo = duel(world)
		world:chat(demo, "/class Demolition")
		world:moveTo(demo, world.Vector3.new(20, 3, 70))
		use(world, demo, world.Vector3.new(20, 3, 120))
		expect.truthy(world:hasNotification(demo, "подойдите ближе"), "далеко")
		use(world, demo, world.Vector3.new(20, 6, 74))
		expect.truthy(
			world:hasNotification(demo, "только на стену или предмет"),
			"в воздух"
		)
		use(world, demo, world.Vector3.new(20, 0, 72)) -- в землю рядом: можно
		expect.truthy(world:hasNotification(demo, "установлен"), "на поверхность — можно")
	end)

	test(
		"взрыв ранит людей рядом, но не самого подрывника",
		function(world, expect)
			local victim, demo = duel(world)
			world:chat(demo, "/class Demolition")
			world:moveTo(demo, world.Vector3.new(20, 3, 70))
			world:moveTo(victim, world.Vector3.new(24, 3, 72))
			local demoBefore = world:humanoid(demo).Health
			local victimBefore = world:humanoid(victim).Health
			use(world, demo, world.Vector3.new(22, 0, 72))
			world:advance(2.1)
			expect.equal(world:humanoid(victim).Health, victimBefore - 40, "жертва ранена")
			expect.equal(world:humanoid(demo).Health, demoBefore, "подрывник цел")
			expect.greater(#world:received(victim, "ExplosionFx"), 0, "эффект взрыва разослан")
		end
	)

	test(
		"Штурмовик: подавление сбивает прицел охране, в которую попал",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local assault = world:addPlayer("Assault", 2)
			world:advance(0.5)
			world:chat(owner, "/cash 46000")
			world:chat(owner, "/upgrade")
			world:chat(owner, "/upgrade")
			world:chat(owner, "/hire Ceiling1 CeilingTurret")
			local plot = world:plot(1)
			local turret = plot.Defense:FindFirstChild("CeilingTurret_Ceiling1")
			world:moveTo(owner, world.Vector3.new(0, 3, 90))
			world:moveTo(assault, world:plotPoint(plot, 0, 3, 4))
			world:equip(assault, "Pistol")
			world:advance(0.5)
			world:fireServer(assault, "Fire", world:aimAt(assault, turret.Head.Position))
			expect.equal(
				turret:GetAttribute("SuppressedUntil"),
				nil,
				"без способности прицел не сбит"
			)
			use(world, assault)
			world:advance(0.31)
			world:fireServer(assault, "Fire", world:aimAt(assault, turret.Head.Position))
			local untilTime = turret:GetAttribute("SuppressedUntil")
			expect.truthy(
				untilTime and untilTime > world.workspace:GetServerTimeNow(),
				"прицел турели сбит"
			)
		end
	)

	test(
		"Разведчик: метка показывает только чужую охрану рядом",
		function(world, expect)
			world:addPlayer("Owner", 1)
			local scout = world:addPlayer("Scout", 2)
			world:advance(0.5)
			world:chat(scout, "/class Stealth")
			world:moveTo(scout, world:plotPoint(world:plot(1), 0, 3, 20))
			use(world, scout)
			local marked = world:received(scout, "MarkDefenders")[1]
			expect.truthy(marked, "метка отправлена")
			expect.equal(
				#marked[1],
				1,
				"отмечен охранник чужого ресторана (свой не считается)"
			)
			expect.equal(marked[2], 10, "длительность 10 с")
		end
	)

	test("мусор в UseAbility отклоняется", function(world, expect)
		local player = world:addPlayer("Player", 1)
		world:fireServer(player, "UseAbility", "abc")
		expect.truthy(
			world:hasWarning("неверный запрос «UseAbility»: аргумент №1"),
			"анти-чит заметил"
		)
	end)

	test("кнопка способности в интерфейсе", function(world, expect)
		local player = world:addPlayer("Player", 1)
		world:advance(0.5)
		world:startClient(player)
		expect.equal(
			world:gui(player, "AbilityButton").Text,
			"Подавление (Q)",
			"способность штурмовика"
		)
		world:chat(player, "/class Tank")
		expect.equal(
			world:gui(player, "AbilityButton").Text,
			"Щит (Q)",
			"сменился класс — сменилась кнопка"
		)
		world:click(world:gui(player, "AbilityButton"))
		expect.truthy(
			world:hasNotification(player, "Щит: урон снижен"),
			"щит включён кнопкой"
		)
	end)
end
