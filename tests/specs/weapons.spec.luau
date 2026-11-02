--[[
	Оружие: выдача, попадания, время доставания, темп, прострел материалов,
	разрушение мебели и стекла, урон по турелям, блик прицела.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function upgradeTo(world, owner, tier: number)
	world:chat(owner, "/cash 200000")
	while world:plot(1):GetAttribute("Tier") < tier do
		world:chat(owner, "/upgrade")
	end
end

local function health(world, player): number
	return world:humanoid(player).Health
end

-- Два игрока в чистом поле, лицом друг к другу (вдали от участков).
local function duel(world)
	local shooter = world:addPlayer("Shooter", 1)
	local target = world:addPlayer("Target", 2)
	world:advance(0.5)
	world:moveTo(shooter, world.Vector3.new(20, 3, 60))
	world:moveTo(target, world.Vector3.new(20, 3, 70))
	return shooter, target
end

local function shoot(world, shooter, targetPosition)
	world:fireServer(shooter, "Fire", world:aimAt(shooter, targetPosition))
end

return function(test)
	test("игрок получает пистолет при появлении", function(world, expect)
		local player = world:addPlayer("Player", 1)
		local pistol = player.Backpack:FindFirstChild("Pistol")
		expect.truthy(pistol, "пистолет в рюкзаке")
		expect.equal(pistol:GetAttribute("WeaponId"), "Pistol", "WeaponId")
	end)

	test("выстрел попадает в другого игрока", function(world, expect)
		local shooter, target = duel(world)
		local before = health(world, target)
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		expect.equal(health(world, target), before - 15, "урон пистолета")
		expect.greater(#world:received(target, "ShotFired"), 0, "цель видит трассер")
		expect.equal(#world:received(shooter, "ShotFired"), 0, "стрелку свой трассер не шлём")
	end)

	test("сразу после взятия оружия выстрелить нельзя", function(world, expect)
		local shooter, target = duel(world)
		local before = health(world, target)
		world:equip(shooter, "Pistol")
		world:advance(0.1)
		shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		expect.equal(health(world, target), before, "оружие ещё достают")
		world:advance(0.4)
		shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		expect.equal(
			health(world, target),
			before - 15,
			"после времени доставания выстрел проходит"
		)
	end)

	test("темп стрельбы ограничен сервером", function(world, expect)
		local shooter, target = duel(world)
		local before = health(world, target)
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		for _ = 1, 5 do
			shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		end
		expect.equal(health(world, target), before - 15, "из пачки засчитан один выстрел")
		world:advance(0.31)
		shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		expect.equal(
			health(world, target),
			before - 30,
			"следующий выстрел — после интервала"
		)
	end)

	test("без оружия в руках выстрел не засчитывается", function(world, expect)
		local shooter, target = duel(world)
		local before = health(world, target)
		world:advance(1)
		shoot(world, shooter, target.Character.HumanoidRootPart.Position)
		expect.equal(health(world, target), before, "урона нет")
	end)

	test("пуля проходит сквозь доски ларька (Tier 1)", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local shooter = world:addPlayer("Shooter", 2)
		world:advance(0.5)
		local plot = world:plot(1)
		world:moveTo(owner, world:plotPoint(plot, 0, 3, 0))
		world:moveTo(shooter, world:plotPoint(plot, 0, 3, -9))
		local before = health(world, owner)
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		shoot(world, shooter, owner.Character.HumanoidRootPart.Position)
		expect.equal(health(world, owner), before - 15, "владелец ранен сквозь стену")
		local wall = plot:FindFirstChild("Restaurant"):FindFirstChild("BackWall", true)
		expect.equal(wall:GetAttribute("Health"), 115, "стена тоже получила урон")
	end)

	test("кирпич (Tier 2) пулю не пропускает", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local shooter = world:addPlayer("Shooter", 2)
		world:advance(0.5)
		upgradeTo(world, owner, 2)
		local plot = world:plot(1)
		world:moveTo(owner, world:plotPoint(plot, 0, 3, 0))
		world:moveTo(shooter, world:plotPoint(plot, 0, 3, -11))
		local before = health(world, owner)
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		shoot(world, shooter, owner.Character.HumanoidRootPart.Position)
		expect.equal(health(world, owner), before, "кирпич остановил пулю")
	end)

	test(
		"бронестекло (Tier 3) пулю не пропускает и не бьётся",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local shooter = world:addPlayer("Shooter", 2)
			world:advance(0.5)
			upgradeTo(world, owner, 3)
			local plot = world:plot(1)
			world:moveTo(owner, world:plotPoint(plot, -8, 3, 5))
			world:moveTo(shooter, world:plotPoint(plot, -8, 3, 13))
			local before = health(world, owner)
			world:equip(shooter, "Pistol")
			world:advance(0.5)
			shoot(world, shooter, owner.Character.HumanoidRootPart.Position)
			expect.equal(health(world, owner), before, "бронестекло остановило пулю")
			local glass = plot:FindFirstChild("Restaurant"):FindFirstChild("FrontLeft", true)
			expect.equal(glass:GetAttribute("Health"), nil, "бронестекло неразрушимо")
		end
	)

	test("обычное стекло (Tier 2) бьётся и открывает проход", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local shooter = world:addPlayer("Shooter", 2)
		world:advance(0.5)
		upgradeTo(world, owner, 2)
		local plot = world:plot(1)
		world:moveTo(owner, world.Vector3.new(0, 3, 70))
		world:moveTo(shooter, world:plotPoint(plot, -6.5, 3, 12))
		local glass = plot:FindFirstChild("Restaurant"):FindFirstChild("FrontLeft", true)
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		for _ = 1, 8 do
			shoot(world, shooter, glass.Position)
			world:advance(0.31)
		end
		expect.equal(glass:GetAttribute("Broken"), true, "стекло разбито")
		expect.equal(glass.CanQuery, false, "лучи и пули больше его не замечают")
		expect.equal(glass.CanCollide, false, "проход открыт")
	end)

	test(
		"стрельба по мебели ломает её, ресторан встаёт, охрана атакует стрелка",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local shooter = world:addPlayer("Shooter", 2)
			world:advance(0.5)
			world:chat(shooter, "/class Demolition") -- урон по конструкциям ×3
			local plot = world:plot(1)
			world:moveTo(owner, world.Vector3.new(0, 3, 70))
			world:moveTo(shooter, world:plotPoint(plot, 0, 3, 9))
			local counter = plot:FindFirstChild("Restaurant"):FindFirstChild("Counter", true)
			world:equip(shooter, "Pistol")
			world:advance(0.5)
			for _ = 1, 10 do
				shoot(world, shooter, counter.Position)
				world:advance(0.31)
			end
			expect.equal(
				counter:GetAttribute("Broken"),
				true,
				"стойка сломана (150 прочности / 15 за выстрел)"
			)
			world:advance(2.5)
			expect.equal(plot:GetAttribute("Operational"), false, "ресторан остановлен")
			local GuardAIService = world:module(SERVICES .. "GuardAIService")
			local PlotService = world:module(SERVICES .. "PlotService")
			expect.truthy(
				GuardAIService:isHostile(PlotService:getPlot(owner), shooter),
				"охрана помнит стрелка"
			)
		end
	)

	test("свою мебель повредить нельзя", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		world:advance(0.5)
		local plot = world:plot(1)
		world:moveTo(owner, world:plotPoint(plot, 0, 3, 9))
		local counter = plot:FindFirstChild("Restaurant"):FindFirstChild("Counter", true)
		world:equip(owner, "Pistol")
		world:advance(0.5)
		shoot(world, owner, counter.Position)
		expect.equal(counter:GetAttribute("Health"), nil, "стойка цела")
	end)

	test("турель получает урон и выходит из строя", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local shooter = world:addPlayer("Shooter", 2)
		local visitor = world:addPlayer("Visitor", 3)
		world:advance(0.5)
		upgradeTo(world, owner, 3)
		local plot = world:plot(1)
		local turret = plot:FindFirstChild("Restaurant"):FindFirstChild("CeilingTurret1", true)
		local turretHead = turret:FindFirstChild("Head")
		world:moveTo(owner, world.Vector3.new(0, 3, 70))
		world:moveTo(shooter, world:plotPoint(plot, 0, 3, 4))
		world:equip(shooter, "Pistol")
		world:advance(0.5)
		shoot(world, shooter, turretHead.Position)
		expect.equal(
			turret:GetAttribute("Health"),
			400 - 15 * 1.5,
			"урон по турели × DefenderDamage штурмовика"
		)

		turret:SetAttribute("Health", 10)
		world:advance(0.31)
		shoot(world, shooter, turretHead.Position)
		expect.equal(turret:GetAttribute("Health"), 0, "турель уничтожена")

		-- Безоружного штурмовика охранник не трогает, а уничтоженная турель больше не стреляет.
		world:moveTo(shooter, world.Vector3.new(0, 3, 70))
		world:moveTo(visitor, world:plotPoint(plot, 0, 3, 4))
		local before = health(world, visitor)
		world:advance(3)
		expect.equal(health(world, visitor), before, "мёртвая турель не стреляет")
	end)

	test(
		"снайперская винтовка: блик виден, пока она в руках",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			world:chat(player, "/weapon Sniper")
			local sniper = world:equip(player, "Sniper")
			expect.truthy(sniper.Handle:FindFirstChild("ScopeGlint"), "блик над винтовкой")
			world:unequip(player)
			expect.falsy(sniper.Handle:FindFirstChild("ScopeGlint"), "блик пропал, когда убрал")
			local pistol = world:equip(player, "Pistol")
			expect.falsy(pistol.Handle:FindFirstChild("ScopeGlint"), "у пистолета блика нет")
		end
	)

	test(
		"купленное оружие сохраняется и выдаётся после возрождения",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			world:chat(player, "/weapon Rifle")
			local DataService = world:module(SERVICES .. "DataService")
			expect.equal(DataService:get(player).Equipment.Weapons.Rifle, 1, "автомат в снаряжении")
			for _, child in player.Backpack:GetChildren() do
				child:Destroy() -- после смерти рюкзак пустеет
			end
			world:spawnCharacter(player)
			expect.truthy(player.Backpack:FindFirstChild("Rifle"), "автомат выдан снова")
			expect.truthy(player.Backpack:FindFirstChild("Pistol"), "пистолет выдан снова")
		end
	)
end
