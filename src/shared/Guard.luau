--!strict
--[[
	Guard — проверка данных, пришедших от клиента.

	ГЛАВНОЕ ПРАВИЛО: всё, что приходит через RemoteEvent, контролирует потенциальный
	читер. Он может прислать любой тип (строку вместо числа, таблицу вместо Instance),
	NaN, бесконечность, отрицательные числа, огромные строки, лишние аргументы.
	Поэтому каждый аргумент каждого Remote проверяется на сервере ДО использования.

	Каждая функция возвращает «проверку» — функцию (value) -> boolean.
	Проверки передаются в NetService:on(имя, { args = { ... } }, обработчик).

	Пример:
		args = { Guard.keyOf(ShopItems), Guard.integer(1, 99) } -- id товара и количество

	Важно: Guard проверяет ФОРМУ данных. Смысл (хватает ли денег, рядом ли
	магазин, не на кулдауне ли способность) проверяет уже сам обработчик.
]]

export type Check = (value: unknown) -> boolean

local Guard = {}

-- Конечное число: отсекает NaN и ±бесконечность.
-- NaN особенно опасен: любое сравнение с ним ложно, поэтому проверки вида
-- «if amount > money then return end» он проходит, а потом ломает данные.
local function isFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Число в диапазоне [min, max] (границы необязательны).
function Guard.number(min: number?, max: number?): Check
	return function(value)
		if not isFiniteNumber(value) then
			return false
		end
		local number = value :: number
		if min ~= nil and number < min then
			return false
		end
		if max ~= nil and number > max then
			return false
		end
		return true
	end
end

-- Целое число в диапазоне [min, max]. Для количеств, индексов, id.
function Guard.integer(min: number?, max: number?): Check
	local inRange = Guard.number(min, max)
	return function(value)
		return inRange(value) and (value :: number) % 1 == 0
	end
end

function Guard.boolean(): Check
	return function(value)
		return typeof(value) == "boolean"
	end
end

-- Строка не длиннее maxBytes байт с корректной кодировкой UTF-8.
-- Некорректный UTF-8 нельзя сохранить в DataStore. Текст, который увидят
-- другие игроки, дополнительно обязательно пропускать через TextService (фильтр).
function Guard.string(maxBytes: number): Check
	return function(value)
		if typeof(value) ~= "string" then
			return false
		end
		local text = value :: string
		return #text <= maxBytes and utf8.len(text) ~= nil
	end
end

-- Значение из фиксированного списка: Guard.oneOf("Sword", "Bow").
function Guard.oneOf(...: string | number | boolean): Check
	local allowed: { [any]: boolean } = {}
	for _, option in { ... } do
		allowed[option] = true
	end
	return function(value)
		return value ~= nil and allowed[value :: any] == true
	end
end

-- Ключ существующей таблицы-справочника: Guard.keyOf(ShopItems) пропустит
-- только реально существующие id товаров.
function Guard.keyOf(dictionary: { [any]: any }): Check
	return function(value)
		local valueType = typeof(value)
		return (valueType == "string" or valueType == "number") and dictionary[value :: any] ~= nil
	end
end

-- Vector3 с конечными координатами и (необязательно) ограниченной длиной.
function Guard.vector3(maxMagnitude: number?): Check
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false
		end
		local vector = value :: Vector3
		if not (isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)) then
			return false
		end
		return maxMagnitude == nil or vector.Magnitude <= maxMagnitude
	end
end

-- Экземпляр заданного класса.
-- ВНИМАНИЕ: сам факт, что клиент прислал Instance, ничего не гарантирует.
-- Обработчик должен проверить, что объект там, где нужно (IsDescendantOf),
-- принадлежит этому игроку и находится рядом с ним. Объекты, созданные
-- клиентом локально, до сервера доходят как nil.
function Guard.instance(className: string): Check
	return function(value)
		return typeof(value) == "Instance" and (value :: Instance):IsA(className)
	end
end

-- Аргумент может отсутствовать (nil) или должен пройти проверку check.
function Guard.optional(check: Check): Check
	return function(value)
		return value == nil or check(value)
	end
end

-- Любое значение. Только если обработчик сам проверяет его дальше
-- (например, когда правило зависит от предыдущего аргумента).
function Guard.any(): Check
	return function()
		return true
	end
end

-- Проверить набор аргументов: их не больше, чем проверок, и каждый проходит свою.
-- Возвращает (успех, номер_плохого_аргумента). При лишних аргументах номер nil.
function Guard.args(checks: { Check }, ...: any): (boolean, number?)
	if select("#", ...) > #checks then
		return false, nil
	end
	for index, check in checks do
		if not check((select(index, ...))) then
			return false, index
		end
	end
	return true, nil
end

return table.freeze(Guard)
