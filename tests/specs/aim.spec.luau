--[[
	Статистика стрельбы против аимбота: «резкие доводки с попаданием»
	(переключение между целями под большим углом за доли секунды).
	Обычная стрельба — по одной цели, промахи, паузы, ближний бой — не считается.
]]

local SERVICES = "ServerScriptService.Server.Services."

-- Стрелок с пистолетом и две цели под прямым углом к нему.
local function arena(world, distance: number)
	local shooter = world:addPlayer("Shooter", 1)
	local front = world:addPlayer("Front", 2)
	local side = world:addPlayer("Side", 3)
	world:advance(0.5)
	world:moveTo(shooter, world.Vector3.new(20, 3, 60))
	world:moveTo(front, world.Vector3.new(20, 3, 60 + distance))
	world:moveTo(side, world.Vector3.new(20 + distance, 3, 60))
	world:equip(shooter, "Pistol")
	world:advance(0.5)
	return shooter, front, side, world:module(SERVICES .. "AimStatsService")
end

local function shootAt(world, shooter, target)
	world:fireServer(shooter, "Fire", world:aimAt(shooter, target.Character.HumanoidRootPart.Position))
end

return function(test)
	test(
		"переключение между целями с попаданиями — подозрение, повтор — кик",
		function(world, expect)
			local shooter, front, side, aim = arena(world, 15)
			local targets = { front, side }
			for shot = 1, 5 do
				shootAt(world, shooter, targets[shot % 2 + 1])
				world:advance(0.3) -- темп пистолета
			end
			expect.equal(
				aim:getStats(shooter).snapHits,
				4,
				"четыре доводки на 90° с попаданием"
			)
			expect.truthy(world:hasWarning("подозрение на аимбот"), "запись в лог")
			expect.equal(world.kicked[shooter], nil, "одно подозрение — ещё не кик")

			for shot = 6, 9 do
				shootAt(world, shooter, targets[shot % 2 + 1])
				world:advance(0.3)
			end
			expect.truthy(world.kicked[shooter], "второе подозрение подряд — кик")
		end
	)

	test(
		"обычная стрельба не считается: одна цель, промахи, паузы, ближний бой",
		function(world, expect)
			local shooter, front, side, aim = arena(world, 15)
			for _ = 1, 5 do
				shootAt(world, shooter, side) -- ведёт одну цель
				world:advance(0.3)
			end
			for _ = 1, 4 do
				-- резкий поворот, но мимо: в пустоту в обратную сторону
				world:fireServer(shooter, "Fire", world.Vector3.new(-1, 0, 0))
				world:advance(0.3)
				shootAt(world, shooter, front) -- резко на цель и попал, но до этого был промах
				world:advance(0.3)
			end
			world:advance(0.8)
			for _ = 1, 2 do
				shootAt(world, shooter, side) -- поворот на 90°, но после паузы
				world:advance(0.8)
				shootAt(world, shooter, front)
				world:advance(0.8)
			end
			local stats = aim:getStats(shooter)
			expect.equal(stats.suspicions, 0, "подозрений нет")
			expect.equal(world:hasWarning("аимбот"), false, "в логе чисто")
			expect.equal(stats.shots, 17, "все выстрелы учтены")
			expect.equal(stats.playerHits, 13, "попадания учтены (цели живы)")
		end
	)

	test("вблизи большие повороты естественны", function(world, expect)
		local shooter, front, side, aim = arena(world, 8)
		local targets = { front, side }
		for shot = 1, 7 do
			shootAt(world, shooter, targets[shot % 2 + 1])
			world:advance(0.3)
		end
		expect.equal(aim:getStats(shooter).playerHits, 7, "все попали")
		expect.equal(aim:getStats(shooter).snapHits, 0, "ближе 12 студов — не доводка")
	end)
end
