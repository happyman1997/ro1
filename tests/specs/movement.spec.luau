--[[
	Проверка перемещения: ходьба, телепорт из эксплойта, лаг, серверный телепорт, возрождение.
]]

local SERVICES = "ServerScriptService.Server.Services."

local function setup(world)
	local player = world:addPlayer("Runner", 1)
	world:advance(0.5)
	world:moveTo(player, world.Vector3.new(0, 3, 100))
	world:advance(0.5)
	return player
end

local function position(player)
	return player.Character.HumanoidRootPart.Position
end

return function(test)
	test("обычная ходьба не считается нарушением", function(world, expect)
		local player = setup(world)
		local start = position(player)
		for step = 1, 20 do
			world:rawMove(player, start + world.Vector3.new(step * 4, 0, 0)) -- 16 студов/с
			world:advance(0.25)
		end
		expect.near(position(player).X, start.X + 80, 0.01, "игрок дошёл")
		expect.falsy(
			world:hasWarning("слишком быстрое перемещение"),
			"нарушений нет"
		)
	end)

	test("телепорт из эксплойта откатывается", function(world, expect)
		local player = setup(world)
		local start = position(player)
		world:rawMove(player, start + world.Vector3.new(150, 0, 0))
		world:advance(0.3)
		expect.less(
			(position(player) - start).Magnitude,
			1,
			"возвращён на последнюю честную позицию"
		)
		expect.truthy(
			world:hasWarning("слишком быстрое перемещение"),
			"анти-чит заметил"
		)
	end)

	test("спидхак (в три раза быстрее) откатывается", function(world, expect)
		local player = setup(world)
		local start = position(player)
		for step = 1, 12 do
			world:rawMove(player, position(player) + world.Vector3.new(12, 0, 0)) -- 48 студов/с
			world:advance(0.25)
		end
		-- Без защиты он ушёл бы на 144 студа; сервер пускает не быстрее 16 × 1,4 = 22,4 ст/с
		-- (около 67 студов за 3 с) плюс накопленный запас пути.
		expect.less(position(player).X - start.X, 90, "скорость ограничена до допустимой")
		expect.truthy(
			world:hasWarning("слишком быстрое перемещение"),
			"анти-чит заметил"
		)
	end)

	test(
		"рывок после лага в пределах запаса пути прощается",
		function(world, expect)
			local player = setup(world)
			local start = position(player)
			world:advance(1.5) -- пакеты не приходили
			world:rawMove(player, start + world.Vector3.new(30, 0, 0))
			world:advance(0.25)
			expect.near(position(player).X, start.X + 30, 0.01, "позиция принята")
			expect.falsy(
				world:hasWarning("слишком быстрое перемещение"),
				"нарушения нет"
			)
		end
	)

	test("полёт вверх откатывается, падение вниз — нет", function(world, expect)
		local player = setup(world)
		local start = position(player)
		world:rawMove(player, start + world.Vector3.new(0, 60, 0))
		world:advance(0.25)
		expect.less(position(player).Y, start.Y + 1, "взлёт откатан")
		world:moveTo(player, start + world.Vector3.new(0, 80, 0))
		world:advance(0.25)
		world:rawMove(player, start)
		world:advance(0.25)
		expect.near(position(player).Y, start.Y, 0.01, "падение принято")
	end)

	test(
		"телепорт по воле сервера и возрождение не считаются нарушением",
		function(world, expect)
			local player = setup(world)
			local MovementService = world:module(SERVICES .. "MovementService")
			MovementService:teleport(player, world.CFrame.new(300, 3, 300))
			world:advance(0.5)
			expect.near(position(player).X, 300, 0.01, "серверный телепорт принят")
			world:spawnCharacter(player)
			world:advance(0.5)
			expect.falsy(
				world:hasWarning("слишком быстрое перемещение"),
				"нарушений нет"
			)
		end
	)
end
