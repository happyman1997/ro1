--[[
	Наём охраны: слоты, цена, уровень, тип слота, сохранение, увольнение, замена павших.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local owner = world:addPlayer("Owner", 1)
	world:advance(0.5)
	return owner, world:plot(1), world:module(SERVICES .. "DataService")
end

local function upgradeTo(world, owner, tier: number)
	world:chat(owner, "/cash 200000")
	while world:plot(1):GetAttribute("Tier") < tier do
		world:chat(owner, "/upgrade")
	end
end

return function(test)
	test("наём вышибалы в слот у входа", function(world, expect)
		local owner, plot, data = setup(world)
		world:chat(owner, "/cash 2000")
		world:chat(owner, "/hire Door1 Bouncer")
		local bouncer = plot.Defense:FindFirstChild("Bouncer_Door1")
		expect.truthy(bouncer, "вышибала стоит на участке")
		expect.equal(bouncer:GetAttribute("DefenderType"), "Bouncer", "тип")
		expect.equal(data:get(owner).Cash, 500, "списано $1500")
		expect.equal(data:get(owner).Restaurant.Defense.Door1, "Bouncer", "наём сохранён в данных")
		local slot = plot:FindFirstChild("Restaurant"):FindFirstChild("Slot_Door1", true)
		expect.less(
			(bouncer:GetPivot().Position - slot.Position).Magnitude,
			0.01,
			"стоит точно в слоте"
		)
	end)

	test(
		"без денег, не по уровню, не в тот слот или в занятый — отказ",
		function(world, expect)
			local owner, plot, data = setup(world)
			world:chat(owner, "/hire Door1 Bouncer")
			expect.truthy(world:hasNotification(owner, "стоит $1500"), "без денег")
			world:chat(owner, "/cash 100000")
			world:chat(owner, "/hire Door1 Gunner")
			expect.truthy(world:hasNotification(owner, "доступен с 2 уровня"), "не по уровню")
			world:chat(owner, "/hire Door1 CeilingTurret")
			expect.truthy(
				world:hasNotification(owner, "не подходит"),
				"турель в слот охранника"
			)
			world:chat(owner, "/hire Nowhere Bouncer")
			expect.truthy(world:hasNotification(owner, "нет слота"), "несуществующий слот")
			world:chat(owner, "/hire Door1 Bouncer")
			world:chat(owner, "/hire Door1 Bouncer")
			expect.truthy(world:hasNotification(owner, "уже занят"), "занятый слот")
			expect.equal(#plot.Defense:GetChildren(), 1, "нанят один")
			expect.equal(data:get(owner).Cash, 98500, "списано только за одного")
		end
	)

	test(
		"нанятая охрана переезжает на новый уровень и остаётся после перезахода",
		function(world, expect)
			local owner, plot = setup(world)
			upgradeTo(world, owner, 3)
			world:chat(owner, "/hire Door1 Gunner")
			world:chat(owner, "/hire Ceiling1 CeilingTurret")
			world:chat(owner, "/upgrade")
			expect.equal(plot:GetAttribute("Tier"), 4, "уровень 4")
			expect.truthy(plot.Defense:FindFirstChild("Gunner_Door1"), "охранник на новом уровне")
			expect.truthy(
				plot.Defense:FindFirstChild("CeilingTurret_Ceiling1"),
				"турель на новом уровне"
			)

			world:removePlayer(owner)
			world:advance(1)
			world:addPlayer("Owner", 1)
			world:advance(0.5)
			expect.truthy(
				world:plot(1).Defense:FindFirstChild("Gunner_Door1"),
				"охранник после перезахода"
			)
			expect.truthy(
				world:plot(1).Defense:FindFirstChild("CeilingTurret_Ceiling1"),
				"турель после перезахода"
			)
		end
	)

	test("увольнение возвращает половину цены", function(world, expect)
		local owner, plot, data = setup(world)
		world:chat(owner, "/cash 1500")
		world:chat(owner, "/hire Door1 Bouncer")
		world:chat(owner, "/dismiss Door1")
		expect.equal(#plot.Defense:GetChildren(), 0, "вышибала ушёл")
		expect.equal(data:get(owner).Cash, 750, "возвращено $750")
		expect.equal(data:get(owner).Restaurant.Defense.Door1, nil, "слот свободен в данных")
	end)

	test(
		"павший охранник возвращается через 45 секунд без боя",
		function(world, expect)
			local owner, plot = setup(world)
			world:chat(owner, "/cash 1500")
			world:chat(owner, "/hire Door1 Bouncer")
			local bouncer = plot.Defense:FindFirstChild("Bouncer_Door1")
			bouncer:FindFirstChildOfClass("Humanoid").Health = 0
			world:advance(30)
			expect.equal(plot.Defense:FindFirstChild("Bouncer_Door1"), bouncer, "ещё не заменён")
			world:advance(20)
			local replacement = plot.Defense:FindFirstChild("Bouncer_Door1")
			expect.truthy(replacement and replacement ~= bouncer, "пришла замена")
			expect.equal(
				replacement:FindFirstChildOfClass("Humanoid").Health,
				250,
				"замена с полным здоровьем"
			)
		end
	)

	test(
		"нанятый стрелок стреляет по вооружённому чужаку",
		function(world, expect)
			local owner, plot = setup(world)
			local intruder = world:addPlayer("Intruder", 2)
			upgradeTo(world, owner, 2)
			world:chat(owner, "/hire Door1 Gunner")
			-- Убираем охранника «из коробки», чтобы стрелял только нанятый.
			plot:FindFirstChild("Restaurant"):FindFirstChild("Gunner", true):Destroy()
			world:moveTo(intruder, world:plotPoint(plot, 3, 3, 12))
			world:equip(intruder, "Pistol")
			local before = world:humanoid(intruder).Health
			world:advance(3)
			expect.less(world:humanoid(intruder).Health, before, "нанятый стрелок попал")
		end
	)

	test("нанимать охрану во время атаки нельзя", function(world, expect)
		local owner, plot = setup(world)
		local intruder = world:addPlayer("Intruder", 2)
		world:chat(owner, "/cash 5000")
		world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
		world:equip(intruder, "Pistol")
		world:advance(2) -- охрана «из коробки» вступает в бой
		world:chat(owner, "/hire Door1 Bouncer")
		expect.truthy(world:hasNotification(owner, "во время атаки"), "отказ")
		expect.equal(#plot.Defense:GetChildren(), 0, "никого не наняли")
	end)

	test("неверные аргументы найма отклоняются", function(world, expect)
		local owner = setup(world)
		world:fireServer(owner, "HireDefender", "Door1", "Dragon")
		expect.truthy(
			world:hasWarning("неверный запрос «HireDefender»: аргумент №2"),
			"неизвестный тип"
		)
		world:advance(1.1)
		world:fireServer(owner, "HireDefender", string.rep("x", 100), "Bouncer")
		expect.truthy(
			world:hasWarning("неверный запрос «HireDefender»: аргумент №1"),
			"слишком длинный слот"
		)
	end)
end
