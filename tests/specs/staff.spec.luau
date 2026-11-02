--[[
	Персонал и вышибала: убитый повар останавливает ресторан, вышибала догоняет
	нарушителя, не уходит дальше поводка и возвращается на пост.
]]

local function setup(world)
	local owner = world:addPlayer("Owner", 1)
	local intruder = world:addPlayer("Intruder", 2)
	world:advance(0.5)
	local plot = world:plot(1)
	-- Убираем охранника «из коробки», чтобы проверять только нужное.
	plot:FindFirstChild("Restaurant"):FindFirstChild("Gunner", true):Destroy()
	world:moveTo(owner, world.Vector3.new(0, 3, 70))
	return owner, intruder, plot
end

local function chefOf(plot)
	return plot:FindFirstChild("Restaurant"):FindFirstChild("Chef", true)
end

return function(test)
	test(
		"убитый повар останавливает ресторан, ремонт возвращает повара",
		function(world, expect)
			local owner, intruder, plot = setup(world)
			local chef = chefOf(plot)
			expect.truthy(chef, "повар на кухне")
			world:moveTo(intruder, world:plotPoint(plot, 0, 3, 9))
			world:equip(intruder, "Pistol")
			world:advance(0.5)
			for _ = 1, 7 do
				world:fireServer(intruder, "Fire", world:aimAt(intruder, chef.HumanoidRootPart.Position))
				world:advance(0.31)
			end
			expect.equal(chef:FindFirstChildOfClass("Humanoid").Health, 0, "повар убит")
			world:advance(2.5)
			expect.equal(plot:GetAttribute("Operational"), false, "ресторан стоит")

			world:moveTo(intruder, world.Vector3.new(0, 3, 90))
			world:advance(25) -- бой закончился
			world:chat(owner, "/cash 500")
			world:chat(owner, "/repair")
			local newChef = chefOf(plot)
			expect.truthy(newChef ~= chef, "новый повар после ремонта")
			expect.greater(newChef:FindFirstChildOfClass("Humanoid").Health, 0, "новый повар жив")
			expect.equal(plot:GetAttribute("Operational"), true, "ресторан снова работает")
		end
	)

	test("вышибала догоняет вооружённого чужака и бьёт", function(world, expect)
		local owner, intruder, plot = setup(world)
		world:chat(owner, "/cash 1500")
		world:chat(owner, "/hire Door1 Bouncer")
		local bouncer = plot.Defense:FindFirstChild("Bouncer_Door1")
		local post = bouncer.HumanoidRootPart.Position
		world:moveTo(intruder, world:plotPoint(plot, 5, 3, 12))
		world:equip(intruder, "Pistol")
		local before = world:humanoid(intruder).Health
		world:advance(3)
		expect.greater(
			(bouncer.HumanoidRootPart.Position - post).Magnitude,
			2,
			"вышибала сдвинулся с поста"
		)
		expect.less(world:humanoid(intruder).Health, before, "вышибала ударил")
	end)

	test(
		"вышибала не уходит дальше поводка и возвращается на пост",
		function(world, expect)
			local owner, intruder, plot = setup(world)
			world:chat(owner, "/cash 1500")
			world:chat(owner, "/hire Door1 Bouncer")
			local bouncer = plot.Defense:FindFirstChild("Bouncer_Door1")
			local post = bouncer.HumanoidRootPart.Position
			world:moveTo(intruder, world:plotPoint(plot, 5, 3, 12))
			world:equip(intruder, "Pistol")
			world:advance(1.5)
			-- Нарушитель отходит далеко: вышибала не бежит за ним через всю карту.
			world:moveTo(intruder, world:plotPoint(plot, 5, 3, 60))
			world:advance(6)
			expect.less((bouncer.HumanoidRootPart.Position - post).Magnitude, 2.5, "вернулся на пост")
			expect.less(
				(bouncer.HumanoidRootPart.Position - post).Magnitude,
				26,
				"не дальше поводка (25 студов) от поста"
			)
		end
	)
end
