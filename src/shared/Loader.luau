--!strict
--[[
	Loader — запуск сервисов (на сервере) и контроллеров (на клиенте) в два этапа.

	1. require всех ModuleScript из папки (по алфавиту, чтобы порядок был стабильным).
	2. Init() у каждого: подготовка СОБСТВЕННОГО состояния. Здесь нельзя
	   рассчитывать на то, что другие модули уже готовы.
	3. Start() у каждого: подключение событий и работа с другими модулями.
	   К этому моменту Init() всех модулей уже выполнен.

	Оба метода необязательны. Ошибка в Init() останавливает запуск
	(игра в полуготовом состоянии опаснее, чем явная ошибка).
	Start() запускается в отдельном потоке, поэтому может ждать (yield),
	не задерживая остальных.
]]

type Module = {
	Init: ((self: any) -> ())?,
	Start: ((self: any) -> ())?,
}

type Entry = { name: string, module: Module }

local Loader = {}

function Loader.run(folder: Instance, label: string)
	local entries: { Entry } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			local module = require(child) :: any
			assert(type(module) == "table", `[{label}] {child.Name} должен возвращать таблицу`)
			table.insert(entries, { name = child.Name, module = module })
		end
	end
	table.sort(entries, function(a: Entry, b: Entry)
		return a.name < b.name
	end)

	for _, entry in entries do
		local init = entry.module.Init
		if init then
			local ok, err = xpcall(init, debug.traceback, entry.module)
			if not ok then
				error(`[{label}] {entry.name}:Init() завершился ошибкой:\n{err}`, 0)
			end
		end
	end

	for _, entry in entries do
		local start = entry.module.Start
		if start then
			task.spawn(start, entry.module)
		end
	end

	print(`[{label}] Запущено модулей: {#entries}`)
end

return Loader
