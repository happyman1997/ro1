--[[
	Охрана: кого видит, в кого стреляет, память тревоги, турели, бронестекло.

	Геометрия тестовой сцены (координаты от Plot.Origin): ларёк Tier 1 открыт спереди (+Z),
	охранник стоит в (-5, 2.9, 2.5) и смотрит на вход. Точка (0, 3, 9) — перед входом.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local owner = world:addPlayer("Owner", 1)
	local intruder = world:addPlayer("Intruder", 2)
	world:advance(0.5)
	return owner, intruder, world:plot(1)
end

local function health(world, player): number
	return world:humanoid(player).Health
end

local function maxHealth(world, player): number
	return world:humanoid(player).MaxHealth
end

-- Улучшить до Tier 3 и нанять потолочную турель в слот Ceiling1.
local function upgradeToTier3(world, owner)
	world:chat(owner, "/cash 46000")
	world:chat(owner, "/upgrade")
	world:chat(owner, "/upgrade")
	assert(world:plot(1):GetAttribute("Tier") == 3, "не удалось улучшить до Tier 3")
	world:chat(owner, "/hire Ceiling1 CeilingTurret")
	assert(world:plot(1).Defense:FindFirstChild("CeilingTurret_Ceiling1"), "турель не нанята")
end

return function(test)
	test("охрана не трогает безоружного чужака у входа", function(world, expect)
		local _, intruder, plot = setup(world)
		world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
		world:advance(3)
		expect.equal(health(world, intruder), maxHealth(world, intruder), "здоровье не тронуто")
	end)

	test("охрана стреляет в чужака с оружием в руках", function(world, expect)
		local owner, intruder, plot = setup(world)
		world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
		world:equip(intruder)
		world:advance(3)
		expect.less(health(world, intruder), maxHealth(world, intruder), "охрана попала")
		expect.truthy(world:hasNotification(owner, "Тревога"), "владельцу пришла тревога")
		expect.greater(#world:received(intruder, "ShotFired"), 0, "клиенту ушли трассеры")
	end)

	test(
		"убрал оружие — охрана помнит, ушёл и вернулся позже — забыла",
		function(world, expect)
			local _, intruder, plot = setup(world)
			world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
			world:equip(intruder)
			world:advance(2)
			world:unequip(intruder)
			local afterUnequip = health(world, intruder)
			world:advance(2)
			expect.less(
				health(world, intruder),
				afterUnequip,
				"после того как убрал оружие, стрельба продолжается"
			)

			world:moveTo(intruder, world.Vector3.new(0, 3, 70)) -- далеко от участка
			world:advance(13)
			world:humanoid(intruder).Health = maxHealth(world, intruder)
			world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
			world:advance(3)
			expect.equal(
				health(world, intruder),
				maxHealth(world, intruder),
				"через 12+ с охрана забыла нарушителя"
			)
		end
	)

	test("владельца охрана не трогает даже с оружием", function(world, expect)
		local owner, _, plot = setup(world)
		world:moveTo(owner, world:plotPoint(plot, 0, 3, 9))
		world:equip(owner)
		world:advance(3)
		expect.equal(health(world, owner), maxHealth(world, owner), "владелец цел")
	end)

	test(
		"турель стреляет в безоружного штурмовика, но не в разведчика в маскировке",
		function(world, expect)
			local owner, intruder, plot = setup(world)
			local scout = world:addPlayer("Scout", 3)
			world:advance(0.5)
			world:chat(scout, "/class Stealth")
			local ClassService = world:module(SERVICES .. "ClassService")
			expect.equal(ClassService:getClassId(scout), "Stealth", "класс разведчика")
			upgradeToTier3(world, owner)

			world:moveTo(intruder, world:plotPoint(plot, 0, 3, 4))
			world:advance(3)
			expect.less(
				health(world, intruder),
				maxHealth(world, intruder),
				"турель стреляет в безоружного штурмовика"
			)

			world:moveTo(intruder, world.Vector3.new(0, 3, 70))
			world:moveTo(scout, world:plotPoint(plot, 0, 3, 4))
			world:advance(3)
			expect.equal(
				health(world, scout),
				maxHealth(world, scout),
				"разведчика в маскировке не видят"
			)
		end
	)

	test(
		"сквозь бронестекло охрана видит, но не стреляет",
		function(world, expect)
			local owner, intruder, plot = setup(world)
			upgradeToTier3(world, owner)
			-- Снаружи перед стеклянной витриной Tier 3 (бронестекло: SeeThrough без ShootThrough).
			world:moveTo(intruder, world:plotPoint(plot, -8, 3, 13))
			world:equip(intruder)
			world:advance(3)
			expect.equal(
				health(world, intruder),
				maxHealth(world, intruder),
				"пули не проходят сквозь бронестекло"
			)
			expect.truthy(world:hasNotification(owner, "Тревога"), "но нарушителя заметили")
		end
	)
end
