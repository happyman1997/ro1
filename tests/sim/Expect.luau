--[[
	Expect — простые проверки для тестов. Ошибка с понятным текстом, если не выполнено.
]]

local Expect = {}

local function show(value): string
	if type(value) == "string" then
		return `"{value}"`
	end
	return tostring(value)
end

function Expect.equal(actual, expected, label: string)
	if actual ~= expected then
		error(`{label}: ожидалось {show(expected)}, получено {show(actual)}`, 2)
	end
end

function Expect.truthy(value, label: string)
	if not value then
		error(`{label}: ожидалось «да», получено {show(value)}`, 2)
	end
end

function Expect.falsy(value, label: string)
	if value then
		error(`{label}: ожидалось «нет», получено {show(value)}`, 2)
	end
end

function Expect.less(actual: number, limit: number, label: string)
	if not (actual < limit) then
		error(`{label}: ожидалось меньше {limit}, получено {actual}`, 2)
	end
end

function Expect.greater(actual: number, limit: number, label: string)
	if not (actual > limit) then
		error(`{label}: ожидалось больше {limit}, получено {actual}`, 2)
	end
end

function Expect.near(actual: number, expected: number, tolerance: number, label: string)
	if math.abs(actual - expected) > tolerance then
		error(`{label}: ожидалось {expected} ± {tolerance}, получено {actual}`, 2)
	end
end

function Expect.errors(fn: () -> (), fragment: string, label: string)
	local ok, err = pcall(fn)
	if ok then
		error(`{label}: ожидалась ошибка`, 2)
	end
	if not string.find(tostring(err), fragment, 1, true) then
		error(`{label}: в ошибке нет «{fragment}»: {tostring(err)}`, 2)
	end
end

return Expect
