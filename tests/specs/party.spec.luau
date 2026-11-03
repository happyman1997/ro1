--[[
	Группы (пати): приглашение через интерфейс, союзники не ранят друг друга,
	охрана союзника не трогает, кассу союзника не взломать, защита от «удара
	в спину», устаревшие и поддельные приглашения, размер группы.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function party(world)
	return world:module(SERVICES .. "PartyService")
end

-- Пригласить и принять «по сети», как это делают клиенты.
local function join(world, inviter, target)
	world:fireServer(inviter, "InviteToParty", target.UserId)
	world:fireServer(target, "RespondPartyInvite", inviter.UserId, true)
end

local function health(world, player): number
	return world:humanoid(player).Health
end

local function shoot(world, shooter, victim)
	world:fireServer(shooter, "Fire", world:aimAt(shooter, victim.Character.HumanoidRootPart.Position))
end

-- Два игрока в чистом поле, лицом друг к другу, у первого пистолет.
local function duel(world)
	local shooter = world:addPlayer("Shooter", 1)
	local friend = world:addPlayer("Friend", 2)
	world:advance(0.5)
	world:moveTo(shooter, world.Vector3.new(20, 3, 60))
	world:moveTo(friend, world.Vector3.new(20, 3, 70))
	world:equip(shooter, "Pistol")
	world:advance(0.5)
	return shooter, friend
end

return function(test)
	test(
		"приглашение приходит в интерфейс, «Принять» объединяет в группу",
		function(world, expect)
			local host = world:addPlayer("Host", 1)
			local guest = world:addPlayer("Guest", 2)
			world:advance(0.5)
			world:startClient(guest)

			world:fireServer(host, "InviteToParty", guest.UserId)
			expect.equal(
				world:gui(guest, "PartyTab").Text,
				"Группа (1)",
				"на вкладке счётчик приглашений"
			)
			world:click(world:gui(guest, "PartyTab"))
			expect.truthy(world:gui(guest, "Row_Invite_1"), "строка приглашения")
			world:click(world:gui(guest, "Accept_1"))

			expect.truthy(party(world):areAllies(host, guest), "сервер объединил в группу")
			expect.equal(
				world:gui(guest, "PartyTab").Text,
				"Группа",
				"приглашение больше не висит"
			)
			expect.truthy(
				string.find(world:gui(guest, "Row_Members").Label.Text, "Группа 2/2", 1, true),
				"состав группы в панели"
			)
			expect.truthy(host.Character:FindFirstChild("AllyHighlight"), "союзник подсвечен")
			expect.truthy(
				world:hasNotification(host, "Guest теперь в группе"),
				"хозяину сообщили"
			)

			world:click(world:gui(guest, "LeavePartyButton"))
			expect.equal(party(world):inParty(guest), false, "вышел из группы")
			expect.equal(party(world):inParty(host), false, "группа из одного распалась")
			expect.equal(host.Character:FindFirstChild("AllyHighlight"), nil, "подсветка снята")
			expect.truthy(
				world:hasNotification(host, "Группа распалась"),
				"хозяину сообщили"
			)
		end
	)

	test("кнопка «Пригласить» отправляет приглашение", function(world, expect)
		local host = world:addPlayer("Host", 1)
		local guest = world:addPlayer("Guest", 2)
		world:advance(0.5)
		world:startClient(host)
		world:click(world:gui(host, "PartyTab"))
		world:click(world:gui(host, "Invite_2"))
		expect.equal(#world:received(guest, "PartyInvite"), 1, "гостю ушло приглашение")

		world:fireServer(guest, "RespondPartyInvite", host.UserId, false)
		expect.equal(party(world):areAllies(host, guest), false, "отказ — не в группе")
		expect.truthy(
			world:hasNotification(host, "Guest отказался"),
			"хозяину сообщили об отказе"
		)
	end)

	test(
		"союзник не ранит союзника, после выхода — снова можно",
		function(world, expect)
			local shooter, friend = duel(world)
			join(world, shooter, friend)
			local before = health(world, friend)
			shoot(world, shooter, friend)
			expect.equal(health(world, friend), before, "пуля союзника не ранит")

			world:fireServer(friend, "LeaveParty")
			world:advance(6) -- больше LeaveGrace
			shoot(world, shooter, friend)
			expect.less(health(world, friend), before, "после выхода из группы — враги")
		end
	)

	test(
		"«удар в спину»: сразу после выхода из группы стрелять по бывшим союзникам нельзя",
		function(world, expect)
			local shooter, friend = duel(world)
			join(world, shooter, friend)
			world:fireServer(shooter, "LeaveParty")
			local before = health(world, friend)
			shoot(world, shooter, friend)
			expect.equal(health(world, friend), before, "ещё 5 секунд — свои")
			world:advance(5.1)
			shoot(world, shooter, friend)
			expect.less(health(world, friend), before, "время вышло — можно")
		end
	)

	test("взрыв подрывника не ранит союзника", function(world, expect)
		local friend = world:addPlayer("Friend", 1)
		local demo = world:addPlayer("Demo", 2)
		local stranger = world:addPlayer("Stranger", 3)
		world:advance(0.5)
		world:chat(demo, "/class Demolition")
		join(world, demo, friend)
		world:moveTo(demo, world.Vector3.new(20, 3, 70))
		world:moveTo(friend, world.Vector3.new(24, 3, 72))
		world:moveTo(stranger, world.Vector3.new(24, 3, 70))
		local friendBefore = health(world, friend)
		local strangerBefore = health(world, stranger)
		world:fireServer(demo, "UseAbility", world.Vector3.new(22, 0, 72))
		world:advance(2.1)
		expect.equal(health(world, friend), friendBefore, "союзник цел")
		expect.less(health(world, stranger), strangerBefore, "чужой ранен")
	end)

	test(
		"охрана не стреляет в вооружённого союзника владельца",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local friend = world:addPlayer("Friend", 2)
			world:advance(0.5)
			join(world, owner, friend)
			local plot = world:plot(1)
			world:moveTo(friend, world:plotPoint(plot, 0, 3, 9))
			world:equip(friend)
			world:advance(3)
			expect.equal(
				health(world, friend),
				world:humanoid(friend).MaxHealth,
				"охрана своих не трогает"
			)
			expect.equal(world:hasNotification(owner, "Тревога"), false, "тревоги нет")

			world:fireServer(friend, "LeaveParty")
			world:advance(9) -- LeaveGrace + время на реакцию охраны
			expect.less(
				health(world, friend),
				world:humanoid(friend).MaxHealth,
				"вышел из группы — чужак"
			)
		end
	)

	test("пули союзника не ломают мебель владельца", function(world, expect)
		local owner = world:addPlayer("Owner", 1)
		local friend = world:addPlayer("Friend", 2)
		world:advance(0.5)
		join(world, owner, friend)
		local plot = world:plot(1)
		local counter = plot:FindFirstChild("Restaurant"):FindFirstChild("Counter", true)
		world:moveTo(friend, world:plotPoint(plot, 0, 3, 9))
		world:equip(friend, "Pistol")
		world:advance(0.5)
		world:fireServer(friend, "Fire", world:aimAt(friend, counter.Position))
		expect.equal(counter:GetAttribute("Health"), nil, "стойка цела")
	end)

	test(
		"разведчик-союзник не может взломать кассу владельца",
		function(world, expect)
			local owner = world:addPlayer("Owner", 1)
			local friend = world:addPlayer("Friend", 2)
			world:advance(0.5)
			world:chat(friend, "/class Stealth")
			join(world, owner, friend)
			local plot = world:plot(1)
			local restaurant = plot:FindFirstChild("Restaurant")
			restaurant:FindFirstChild("Gunner", true):Destroy() -- чтобы мешала только дружба
			local register = world:findTagged(restaurant, "CashRegister")
			local plotService = world:module(SERVICES .. "PlotService")
			world:module(SERVICES .. "CashRegisterService"):deposit(plotService:getPlot(owner), 1200)
			world:moveTo(owner, world.Vector3.new(0, 3, 70))
			world:moveTo(friend, register.Position + world.Vector3.new(0, -1, 2.2))
			world:trigger(friend, world:findPrompt(register, "Hack"))
			expect.equal(#world:received(friend, "HackState"), 0, "взлом не начался")
		end
	)

	test("приглашение устаревает через 30 секунд", function(world, expect)
		local host = world:addPlayer("Host", 1)
		local guest = world:addPlayer("Guest", 2)
		world:advance(0.5)
		world:fireServer(host, "InviteToParty", guest.UserId)
		world:advance(31)
		world:fireServer(guest, "RespondPartyInvite", host.UserId, true)
		expect.equal(party(world):areAllies(host, guest), false, "не в группе")
		expect.truthy(world:hasNotification(guest, "Приглашение устарело"), "объяснение")
	end)

	test(
		"принять несуществующее приглашение нельзя, мусор отклоняется",
		function(world, expect)
			local host = world:addPlayer("Host", 1)
			local cheater = world:addPlayer("Cheater", 2)
			local other = world:addPlayer("Other", 3) -- журнал античита пишет по игроку раз в несколько секунд
			world:advance(0.5)
			world:fireServer(cheater, "RespondPartyInvite", host.UserId, true)
			expect.equal(
				party(world):areAllies(host, cheater),
				false,
				"без приглашения — не в группе"
			)
			world:fireServer(cheater, "InviteToParty", "Host")
			expect.truthy(
				world:hasWarning("неверный запрос «InviteToParty»: аргумент №1"),
				"строка вместо userId"
			)
			world:fireServer(other, "RespondPartyInvite", host.UserId, "yes")
			expect.truthy(
				world:hasWarning("неверный запрос «RespondPartyInvite»: аргумент №2"),
				"не boolean"
			)
			world:fireServer(cheater, "InviteToParty", cheater.UserId)
			expect.equal(#world:received(cheater, "PartyInvite"), 0, "себя не пригласить")
		end
	)

	test(
		"в группе не больше двух, вышедший с сервера убирается из группы",
		function(world, expect)
			local host = world:addPlayer("Host", 1)
			local first = world:addPlayer("First", 2)
			local second = world:addPlayer("Second", 3)
			world:advance(0.5)
			world:fireServer(host, "InviteToParty", first.UserId)
			world:fireServer(host, "InviteToParty", second.UserId)
			world:fireServer(first, "RespondPartyInvite", host.UserId, true)
			world:fireServer(second, "RespondPartyInvite", host.UserId, true)
			expect.equal(#party(world):getMembers(host), 2, "двое в группе")
			expect.truthy(
				world:hasNotification(second, "Группа уже полная"),
				"второе приглашение не сработало"
			)
			expect.equal(party(world):inParty(second), false, "третий не вошёл")

			world:fireServer(host, "InviteToParty", second.UserId)
			expect.truthy(
				world:hasNotification(host, "В группе уже 2"),
				"новое приглашение не отправить"
			)

			world:removePlayer(first)
			expect.equal(
				party(world):inParty(host),
				false,
				"вышедший с сервера убран, группа распалась"
			)
			expect.truthy(
				world:hasNotification(host, "Группа распалась"),
				"хозяину сообщили"
			)
		end
	)

	test(
		"в Studio у тестовых игроков отрицательные UserId — группа работает",
		function(world, expect)
			-- Test → Clients and Servers: Player1 = -1, Player2 = -2.
			local first = world:addPlayer("Player1", -1)
			local second = world:addPlayer("Player2", -2)
			world:advance(0.5)
			world:startClient(first)
			world:click(world:gui(first, "PartyTab"))
			world:click(world:gui(first, "Invite_-2"))
			expect.equal(#world:received(second, "PartyInvite"), 1, "приглашение дошло")
			world:fireServer(second, "RespondPartyInvite", -1, true)
			expect.truthy(party(world):areAllies(first, second), "в группе")
		end
	)
end
