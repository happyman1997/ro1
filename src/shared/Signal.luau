--!strict
--[[
	Signal — лёгкая замена BindableEvent для общения модулей ВНУТРИ одной стороны
	(сервис ↔ сервис на сервере или контроллер ↔ контроллер на клиенте).

	Почему не BindableEvent: он копирует таблицы при передаче (теряются ссылки
	и метатаблицы) и работает медленнее. Signal передаёт аргументы как есть.

	Обработчики запускаются через task.spawn: ошибка в одном не ломает остальные,
	а обработчик без yield успевает выполниться до возврата из Fire.
	Порядок вызова обработчиков не гарантируется.

	Пример:
		local changed = Signal.new() :: Signal.Signal<number>
		local connection = changed:Connect(function(value) print(value) end)
		changed:Fire(42)
		connection:Disconnect()
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

-- Внутреннее устройство объекта (снаружи видно только тип Signal<T...>).
type SignalImpl = {
	_handlers: { [Connection]: (...any) -> () },
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self: SignalImpl = { _handlers = {} }
	return (setmetatable(self, Signal) :: any) :: Signal<T...>
end

function Signal.Connect(self: SignalImpl, handler: (...any) -> ()): Connection
	local handlers = self._handlers
	local connection: Connection = {
		Connected = true,
		Disconnect = function(conn: Connection)
			conn.Connected = false
			handlers[conn] = nil
		end,
	}
	handlers[connection] = handler
	return connection
end

function Signal.Once(self: SignalImpl, handler: (...any) -> ()): Connection
	local connection: Connection
	connection = Signal.Connect(self, function(...: any)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal.Wait(self: SignalImpl): ...any
	local thread = coroutine.running()
	Signal.Once(self, function(...: any)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self: SignalImpl, ...: any)
	-- Перебираем копию: обработчик может подключать/отключать другие обработчики прямо во время Fire.
	for connection, handler in table.clone(self._handlers) do
		if connection.Connected then
			task.spawn(handler, ...)
		end
	end
end

function Signal.DisconnectAll(self: SignalImpl)
	for connection in self._handlers do
		connection.Connected = false
	end
	table.clear(self._handlers)
end

return Signal
