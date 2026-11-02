--[[
	Данные и защита: проверка значений, миграции, смена класса, проверки Remote, анти-флуд.
]]

local SERVICES = "ServerScriptService.Server.Services."

return function(test)
	test("DataService не даёт сохранить NaN", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local DataService = world:module(SERVICES .. "DataService")
		expect.errors(function()
			DataService:set(owner, "Cash", 0 / 0)
		end, "NaN", "NaN отклонён")
		expect.equal(DataService:get(owner).Cash, 0, "значение не изменилось")
	end)

	test("миграция данных 1 → 2 переносит Coins в Cash", function(_world, expect)
		local Migrations = _world:module("ServerScriptService.Server.Modules.Migrations")
		local data = { Version = 1, Coins = 5 }
		Migrations[1](data)
		expect.equal(data.Cash, 5, "Cash")
		expect.equal(data.Coins, nil, "Coins удалено")
	end)

	test("смена класса только на своей территории", function(world, expect)
		world:addPlayer("Owner", 1)
		local intruder = world:addPlayer("Intruder", 2)
		world:advance(0.5)
		local ClassService = world:module(SERVICES .. "ClassService")

		world:moveTo(intruder, world:plotPoint(world:plot(1), 0, 3, 9))
		world:chat(intruder, "/class Tank")
		expect.equal(
			ClassService:getClassId(intruder),
			"Assault",
			"на чужой территории класс не меняется"
		)
		expect.truthy(
			world:hasNotification(intruder, "только на территории своего ресторана"),
			"объяснение"
		)

		world:moveTo(intruder, world:plot(2):FindFirstChild("Spawn").Position + world.Vector3.new(0, 3, 0))
		world:chat(intruder, "/class Tank")
		expect.equal(
			ClassService:getClassId(intruder),
			"Tank",
			"на своей территории класс меняется"
		)
		expect.equal(world:humanoid(intruder).MaxHealth, 300, "здоровье Танка")
	end)

	test(
		"неверные аргументы Remote отклоняются и наказываются",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			local ClassService = world:module(SERVICES .. "ClassService")
			world:fireServer(player, "SelectClass", 123)
			expect.truthy(
				world:hasWarning("неверный запрос «SelectClass»: аргумент №1"),
				"число вместо имени класса"
			)
			world:advance(1.1) -- анти-чит пишет в лог не чаще раза в секунду на игрока
			world:fireServer(player, "SelectClass", "Tank", "лишний")
			expect.truthy(world:hasWarning("лишние аргументы"), "лишний аргумент")
			expect.equal(ClassService:getClassId(player), "Assault", "класс не изменился")
		end
	)

	test(
		"настройки: правильное значение сохраняется, неправильное отклоняется",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			local DataService = world:module(SERVICES .. "DataService")
			world:fireServer(player, "ChangeSetting", "MusicVolume", 0.3)
			expect.equal(DataService:get(player).Settings.MusicVolume, 0.3, "громкость сохранена")
			world:fireServer(player, "ChangeSetting", "MusicVolume", 5)
			expect.equal(DataService:get(player).Settings.MusicVolume, 0.3, "громкость 5 отклонена")
			world:fireServer(player, "ChangeSetting", "MusicVolume", 0 / 0)
			expect.equal(DataService:get(player).Settings.MusicVolume, 0.3, "NaN отклонён")
			expect.truthy(
				world:hasWarning("недопустимое значение настройки"),
				"анти-чит заметил"
			)
		end
	)

	test("флуд запросами приводит к кику", function(world, expect)
		local player = world:addPlayer("Player", 1)
		for _ = 1, 100 do
			world:fireServer(player, "ChangeSetting", "ShowTips", false)
		end
		expect.truthy(world.kicked[player], "флудер кикнут")
	end)

	test(
		"клиент не может отправлять в серверные события",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			world:fireServer(player, "DataSync", "Full", {})
			expect.truthy(
				world:hasWarning("отправка в серверное событие «DataSync»"),
				"анти-чит заметил"
			)
		end
	)

	test("чат-команды проверяют аргументы", function(world, expect)
		local player = world:addPlayer("Player", 1)
		local DataService = world:module(SERVICES .. "DataService")
		world:chat(player, "/cash -5")
		world:chat(player, "/cash abc")
		world:chat(player, "/cash 99999999999")
		expect.equal(DataService:get(player).Cash, 0, "неверные суммы отклонены")
		world:chat(player, "/cash 250")
		expect.equal(DataService:get(player).Cash, 250, "верная сумма начислена")
	end)
end
