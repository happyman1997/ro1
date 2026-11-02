--[[
	Глобальные рейтинги: порядок по деньгам и по украденному, первое
	обновление после запуска, ушедшие игроки остаются в топе, размер топа,
	новичок сразу получает рейтинги, панель «Рейтинг» в интерфейсе.

	В симуляторе место не опубликовано (PlaceId = 0), поэтому рейтинги живут
	в памяти сервера — как и сохранения.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function services(world)
	return world:module(SERVICES .. "LeaderboardService"), world:module(SERVICES .. "DataService")
end

local function names(rows)
	local list = {}
	for _, row in rows do
		table.insert(list, `{row.name}:{row.value}`)
	end
	return table.concat(list, ", ")
end

return function(test)
	test(
		"первое обновление через 5 секунд: самые богатые по порядку",
		function(world, expect)
			local a = world:addPlayer("Ann", 1)
			local b = world:addPlayer("Bob", 2)
			local c = world:addPlayer("Cid", 3)
			world:advance(0.5)
			local boards, data = services(world)
			data:set(a, "Cash", 500)
			data:set(b, "Cash", 900)
			data:set(c, "Cash", 300)
			world:advance(5)
			expect.equal(
				names(boards:getBoard("Richest")),
				"Bob:900, Ann:500, Cid:300",
				"порядок по деньгам"
			)
			local sent = world:received(a, "LeaderboardUpdate")
			expect.equal(#sent, 1, "игрокам разослан рейтинг")
			expect.equal(sent[1][1].Richest[1].name, "Bob", "в событии тот же топ")
		end
	)

	test(
		"лучшие воры — по украденному, обновление раз в 3 минуты",
		function(world, expect)
			local a = world:addPlayer("Ann", 1)
			local b = world:addPlayer("Bob", 2)
			world:advance(6)
			local boards, data = services(world)
			data:update(b, "Stats", function(stats)
				stats.CashStolen = 1500.7
				return stats
			end)
			data:update(a, "Stats", function(stats)
				stats.CashStolen = 200
				return stats
			end)
			world:advance(60)
			expect.equal(
				names(boards:getBoard("Thieves")),
				"Ann:0, Bob:0",
				"до обновления — старые значения"
			)
			world:advance(120)
			expect.equal(
				names(boards:getBoard("Thieves")),
				"Bob:1500, Ann:200",
				"после обновления; дробное округлено вниз"
			)
		end
	)

	test(
		"ушедший игрок остаётся в рейтинге со своим значением",
		function(world, expect)
			local rich = world:addPlayer("Rich", 1)
			world:addPlayer("Stay", 2)
			world:advance(0.5)
			local boards, data = services(world)
			data:set(rich, "Cash", 777)
			world:removePlayer(rich)
			world:advance(6)
			expect.equal(boards:getBoard("Richest")[1].name, "Rich", "записан при выходе")
			expect.equal(boards:getBoard("Richest")[1].value, 777, "с последним значением")
		end
	)

	test("в рейтинге не больше 10 мест", function(world, expect)
		world:addPlayer("Host", 100)
		world:advance(0.5)
		local boards, data = services(world)
		for index = 1, 12 do
			local player = world:addPlayer("P" .. index, index)
			world:advance(0.1)
			data:set(player, "Cash", index * 100)
			world:removePlayer(player)
		end
		world:advance(6)
		local rows = boards:getBoard("Richest")
		expect.equal(#rows, 10, "десять мест")
		expect.equal(rows[1].name, "P12", "первый — самый богатый")
		expect.equal(rows[10].name, "P3", "двое самых бедных не попали")
	end)

	test("из Studio в настоящие рейтинги не пишем", function(world, expect)
		local boards = services(world)
		expect.equal(
			boards.writeAllowed(true, true),
			false,
			"Studio + настоящий DataStore — только чтение"
		)
		expect.equal(boards.writeAllowed(true, false), true, "живой сервер пишет")
		expect.equal(
			boards.writeAllowed(false, true),
			true,
			"Studio без публикации пишет в память"
		)
	end)

	test("новичок получает рейтинг сразу при входе", function(world, expect)
		world:addPlayer("Old", 1)
		world:advance(6)
		local late = world:addPlayer("Late", 2)
		world:advance(0.5)
		expect.equal(
			#world:received(late, "LeaderboardUpdate"),
			1,
			"не ждёт следующего обновления"
		)
	end)

	test(
		"панель «Рейтинг» показывает топ и выделяет себя",
		function(world, expect)
			local me = world:addPlayer("Me", 1)
			local other = world:addPlayer("Other", 2)
			world:advance(0.5)
			local _, data = services(world)
			data:set(me, "Cash", 1500)
			data:set(other, "Cash", 25000)
			world:startClient(me)
			world:advance(5)
			world:click(world:gui(me, "LeaderboardTab"))
			expect.equal(
				world:gui(me, "Row_Rank_Richest_1").Label.Text,
				"1. Other — $25 000",
				"первое место"
			)
			expect.equal(
				world:gui(me, "Row_Rank_Richest_2").Label.Text,
				"2. Me (вы) — $1 500",
				"своя строка"
			)
			expect.equal(
				world:gui(me, "Row_Board_Thieves").Label.Text,
				"Лучшие воры",
				"второй рейтинг"
			)
		end
	)
end
