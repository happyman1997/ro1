--[[
	Запуск автотестов в симуляторе сервера.

	Использование (из корня репозитория):
		rojo build default.project.json -o build/ro1.rbxlx
		lune run tests/run.luau build/ro1.rbxlx [фильтр] [--verbose]

	Каждый тест получает свежий мир: место загружается заново, серверный код
	запускается с нуля. Тест падает, если:
	  • не выполнилась проверка Expect;
	  • в любом серверном потоке произошла необработанная ошибка;
	  • сервер написал предупреждение со словом «Ошибка» (это пишут обработчики
	    ошибок в циклах ИИ, кассы и дохода).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local World = require("./sim/World")
local Expect = require("./sim/Expect")

local placePath = process.args[1]
assert(placePath, "Укажите путь к собранному месту: lune run tests/run.luau build/ro1.rbxlx")
local filter: string? = nil
local verbose = false
for index = 2, #process.args do
	local arg = process.args[index]
	if arg == "--verbose" then
		verbose = true
	else
		filter = arg
	end
end

local place = roblox.deserializePlace(fs.readFile(placePath))

type Test = { file: string, name: string, fn: (any, any) -> () }
local tests: { Test } = {}
local currentFile = ""
local function test(name: string, fn)
	table.insert(tests, { file = currentFile, name = name, fn = fn })
end

local files = {}
for _, name in fs.readDir("tests/specs") do
	if string.match(name, "%.spec%.luau$") then
		table.insert(files, name)
	end
end
table.sort(files)
for _, name in files do
	currentFile = name
	local register = require("./specs/" .. string.gsub(name, "%.luau$", ""))
	register(test)
end

local passed, failed = 0, 0
local failures = {}
for _, entry in tests do
	local fullName = `{entry.file} › {entry.name}`
	if filter and not string.find(fullName, filter, 1, true) then
		continue
	end

	local world = World.new(place, { verbose = verbose })
	local problem: string? = nil
	local ok, err = pcall(function()
		world:start()
		local thread = coroutine.create(entry.fn)
		local resumed, message = coroutine.resume(thread, world, Expect)
		if not resumed then
			error(debug.traceback(thread, tostring(message)), 0)
		end
		if coroutine.status(thread) ~= "dead" then
			error(
				"тест не должен ждать сам (task.wait) — используйте world:advance()",
				0
			)
		end
	end)
	if not ok then
		problem = tostring(err)
	elseif #world.errors > 0 then
		problem = "ошибка в серверном коде:\n" .. world.errors[1]
	else
		for _, warning in world.warnings do
			if string.find(warning, "Ошибка", 1, true) or string.find(warning, "ошибкой", 1, true) then
				problem = "сервер сообщил об ошибке: " .. warning
				break
			end
		end
	end

	if problem then
		failed += 1
		table.insert(failures, { name = fullName, problem = problem })
		print(`✗ {fullName}`)
	else
		passed += 1
		print(`✓ {fullName}`)
	end
end

if #failures > 0 then
	print("\nНе прошли:")
	for _, failure in failures do
		print(`\n✗ {failure.name}\n  {string.gsub(failure.problem, "\n", "\n  ")}`)
	end
end
print(`\nИтого: прошло {passed}, не прошло {failed}`)
process.exit(if failed > 0 or passed == 0 then 1 else 0)
