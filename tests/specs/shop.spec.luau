--[[
	Магазин оружия: покупка, нехватка денег, повторная покупка, бесплатное оружие, неверный id.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local player = world:addPlayer("Player", 1)
	world:advance(0.5)
	return player, world:module(SERVICES .. "DataService")
end

return function(test)
	test(
		"покупка автомата: деньги списаны, оружие в рюкзаке и в снаряжении",
		function(world, expect)
			local player, data = setup(world)
			world:chat(player, "/cash 10000")
			world:fireServer(player, "BuyWeapon", "Rifle")
			expect.equal(data:get(player).Cash, 2000, "списано $8000")
			expect.equal(data:get(player).Equipment.Weapons.Rifle, 1, "в снаряжении")
			expect.truthy(player.Backpack:FindFirstChild("Rifle"), "в рюкзаке")
		end
	)

	test("без денег купить нельзя", function(world, expect)
		local player, data = setup(world)
		world:chat(player, "/cash 100")
		world:fireServer(player, "BuyWeapon", "Sniper")
		expect.equal(data:get(player).Cash, 100, "деньги не тронуты")
		expect.equal(data:get(player).Equipment.Weapons.Sniper, nil, "оружия нет")
		expect.truthy(world:hasNotification(player, "стоит $20000"), "сообщение о цене")
	end)

	test("купленное повторно не покупается", function(world, expect)
		local player, data = setup(world)
		world:chat(player, "/cash 20000")
		world:fireServer(player, "BuyWeapon", "Rifle")
		world:fireServer(player, "BuyWeapon", "Rifle")
		expect.equal(data:get(player).Cash, 12000, "списано один раз")
		expect.truthy(world:hasNotification(player, "уже куплен"), "сообщение")
	end)

	test("бесплатный пистолет не продаётся", function(world, expect)
		local player, data = setup(world)
		world:chat(player, "/cash 100")
		world:fireServer(player, "BuyWeapon", "Pistol")
		expect.equal(data:get(player).Cash, 100, "деньги не тронуты")
		expect.truthy(world:hasNotification(player, "выдаётся всем"), "сообщение")
	end)

	test("неизвестное оружие отклоняется", function(world, expect)
		local player = setup(world)
		world:fireServer(player, "BuyWeapon", "Rocket")
		expect.truthy(
			world:hasWarning("неверный запрос «BuyWeapon»: аргумент №1"),
			"анти-чит заметил"
		)
	end)
end
