--[[
	Клиентский код в симуляторе: запуск контроллеров, подсказки кассы,
	стрельба кликом по мыши, копия данных на клиенте.
]]

return function(test)
	test(
		"клиентские контроллеры запускаются без ошибок и получают данные",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			world:advance(0.5)
			world:startClient(player)
			world:chat(player, "/cash 321")
			local StateController =
				world:module("StarterPlayer.StarterPlayerScripts.Client.Controllers.StateController")
			expect.equal(StateController:get("Cash"), 321, "клиент видит деньги")
			expect.truthy(
				world:hasNotification(player, "Подобрано") == false,
				"лишних уведомлений нет"
			)
		end
	)

	test(
		"подсказки кассы: своя — «Забрать», чужая — «Взломать» только разведчику",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			world:addPlayer("Other", 2)
			world:advance(0.5)
			world:startClient(player)
			local function register(index)
				return world:findTagged(world:plot(index):FindFirstChild("Restaurant"), "CashRegister")
			end
			expect.equal(
				world:findPrompt(register(1), "Collect").Enabled,
				true,
				"своя касса: сбор виден"
			)
			expect.equal(
				world:findPrompt(register(1), "Hack").Enabled,
				false,
				"своя касса: взлома нет"
			)
			expect.equal(
				world:findPrompt(register(2), "Collect").Enabled,
				false,
				"чужая касса: сбора нет"
			)
			expect.equal(
				world:findPrompt(register(2), "Hack").Enabled,
				false,
				"штурмовик не видит взлом"
			)
			world:chat(player, "/class Stealth")
			expect.equal(
				world:findPrompt(register(2), "Hack").Enabled,
				true,
				"разведчик видит взлом"
			)
		end
	)

	test(
		"клик оружием стреляет туда, куда указывает мышь",
		function(world, expect)
			local shooter = world:addPlayer("Shooter", 1)
			local target = world:addPlayer("Target", 2)
			world:advance(0.5)
			world:startClient(shooter)
			world:moveTo(shooter, world.Vector3.new(20, 3, 60))
			world:moveTo(target, world.Vector3.new(20, 3, 70))
			local pistol = world:equip(shooter, "Pistol")
			world:advance(0.5)
			world.mouse.Hit = world.CFrame.new(target.Character.HumanoidRootPart.Position)
			local before = world:humanoid(target).Health
			world:click(pistol)
			expect.equal(world:humanoid(target).Health, before - 15, "попадание")
		end
	)

	test(
		"разведчик не видит «Взломать» на кассе союзника по группе",
		function(world, expect)
			local player = world:addPlayer("Player", 1)
			local friend = world:addPlayer("Friend", 2)
			world:advance(0.5)
			world:startClient(player)
			world:chat(player, "/class Stealth")
			local friendRegister = world:findTagged(world:plot(2):FindFirstChild("Restaurant"), "CashRegister")
			local hack = world:findPrompt(friendRegister, "Hack")
			expect.equal(hack.Enabled, true, "чужая касса: взлом виден")

			world:fireServer(friend, "InviteToParty", player.UserId)
			world:fireServer(player, "RespondPartyInvite", friend.UserId, true)
			expect.equal(hack.Enabled, false, "касса союзника: взлома нет")

			world:fireServer(player, "LeaveParty")
			expect.equal(hack.Enabled, true, "вышел из группы — снова чужая касса")
		end
	)
end
