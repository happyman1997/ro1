--[[
	World — симулятор сервера Roblox для автотестов (запускается в Lune).

	Что делает:
	• Берёт собранный файл места (rojo build), переносит все объекты в имитацию
	  экземпляров Roblox и запускает НАСТОЯЩИЙ серверный код игры (Main.server).
	• Имитирует то, что нужно игре: дерево экземпляров, свойства, атрибуты,
	  теги и CollectionService, события, игроков и персонажей, Humanoid,
	  RemoteEvent, ProximityPrompt, чат-команды, лучи (Raycast) по деталям.
	• Время виртуальное: task.wait / task.delay / os.clock двигаются только
	  через world:advance(секунды), поэтому 60 секунд игры проходят мгновенно
	  и тесты воспроизводимы.

	Чего нет: физики, клиента, рендера. Это проверка логики сервера.
]]

local roblox = require("@lune/roblox")
local luau = require("@lune/luau")

local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
local Color3 = roblox.Color3
local Enum = roblox.Enum
local UDim = roblox.UDim
local UDim2 = roblox.UDim2

local World = {}
World.__index = World

--------------------------------------------------------------------------------
-- Классы, свойства, методы
--------------------------------------------------------------------------------

local NIL = table.freeze({}) -- значение по умолчанию «nil» для известных свойств

local SUPER = {
	Part = "BasePart",
	SpawnLocation = "Part",
	MeshPart = "BasePart",
	WedgePart = "BasePart",
	TrussPart = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	PVInstance = "Instance",
	Tool = "BackpackItem",
	BackpackItem = "Instance",
	RemoteEvent = "BaseRemoteEvent",
	UnreliableRemoteEvent = "BaseRemoteEvent",
	BaseRemoteEvent = "Instance",
	IntValue = "ValueBase",
	NumberValue = "ValueBase",
	StringValue = "ValueBase",
	BoolValue = "ValueBase",
	ValueBase = "Instance",
	ModuleScript = "LuaSourceContainer",
	Script = "BaseScript",
	LocalScript = "Script",
	BaseScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
}

local function superOf(className: string): string?
	if className == "Instance" then
		return nil
	end
	return SUPER[className] or "Instance"
end

local PROPS = {
	Instance = { Archivable = true },
	BasePart = {
		Anchored = false,
		Size = Vector3.new(4, 1.2, 2),
		CFrame = CFrame.new(),
		Transparency = 0,
		CanCollide = true,
		CanTouch = true,
		CanQuery = true,
		Locked = false,
		CastShadow = true,
		Color = Color3.new(0.64, 0.64, 0.64),
		Material = Enum.Material.Plastic,
	},
	SpawnLocation = { Neutral = true, Duration = 10, Enabled = true, AllowTeamChangeOnTouch = false },
	Model = { PrimaryPart = NIL, WorldPivot = CFrame.new() },
	Humanoid = {
		Health = 100,
		MaxHealth = 100,
		WalkSpeed = 16,
		JumpPower = 50,
		RequiresNeck = true,
		BreakJointsOnDeath = true,
	},
	Attachment = { CFrame = CFrame.new() },
	ProximityPrompt = {
		Enabled = true,
		HoldDuration = 0,
		MaxActivationDistance = 10,
		ActionText = "Interact",
		ObjectText = "",
		KeyboardKeyCode = Enum.KeyCode.E,
		RequiresLineOfSight = true,
	},
	IntValue = { Value = 0 },
	NumberValue = { Value = 0 },
	StringValue = { Value = "" },
	BoolValue = { Value = false },
	Tool = { CanBeDropped = true, RequiresHandle = true, ToolTip = "", Enabled = true },
	LuaSourceContainer = { Source = "" },
	Player = { UserId = 0, DisplayName = "", Character = NIL, RespawnLocation = NIL },
	TextChatCommand = { PrimaryAlias = "", SecondaryAlias = "", Enabled = true },
	BillboardGui = {
		Size = UDim2.new(),
		AlwaysOnTop = false,
		LightInfluence = 1,
		MaxDistance = math.huge,
		StudsOffset = Vector3.new(),
		Adornee = NIL,
		Enabled = true,
	},
	Frame = {
		Size = UDim2.new(),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0,
		BorderSizePixel = 1,
	},
	UICorner = { CornerRadius = UDim.new() },
	DataModel = { PlaceId = 0, GameId = 0, JobId = "" },
}

-- Свойства, которые копируются из файла места.
local COPY_PROPS = {
	BasePart = {
		"Size",
		"CFrame",
		"Anchored",
		"Transparency",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"Color",
		"Material",
	},
	SpawnLocation = { "Neutral", "Duration", "Enabled" },
	Model = { "WorldPivot" },
	Attachment = { "CFrame" },
	LuaSourceContainer = { "Source" },
	Tool = { "CanBeDropped", "ToolTip" },
}

local EVENTS = {
	ChildAdded = true,
	ChildRemoved = true,
	Destroying = true,
	Triggered = true,
	OnServerEvent = true,
	OnClientEvent = true,
	PlayerAdded = true,
	PlayerRemoving = true,
	CharacterAdded = true,
	CharacterRemoving = true,
	Died = true,
	Touched = true,
	Changed = true,
}

-- Правильный CFrame.lookAt (в Lune 0.10 он считается неверно).
local function lookAt(at, target, up)
	up = up or Vector3.new(0, 1, 0)
	local look = target - at
	if look.Magnitude < 1e-9 then
		return CFrame.new(at)
	end
	look = look.Unit
	local right = look:Cross(up)
	if right.Magnitude < 1e-9 then
		right = look:Cross(Vector3.new(0, 0, 1))
	end
	right = right.Unit
	return CFrame.fromMatrix(at, right, right:Cross(look))
end

--------------------------------------------------------------------------------
-- Мир
--------------------------------------------------------------------------------

export type World = typeof(setmetatable({} :: any, World))

function World.new(place, options: { verbose: boolean? }?)
	local self = setmetatable({}, World)
	self.verbose = options and options.verbose or false
	self.now = 0
	self.baseTime = 1_750_000_000
	self.seq = 0
	self.queue = {} -- { time, seq, thread, args }
	self.deferred = {}
	self.errors = {}
	self.warnings = {}
	self.prints = {}
	self.sent = {} -- события сервер → клиент: { remote, player, args }
	self.kicked = {} -- [player] = сообщение
	self.networkOwners = {}
	self.state = setmetatable({}, { __mode = "k" }) -- экземпляр → внутреннее состояние
	self.tagSignals = { added = {}, removed = {} }
	self.modules = {} -- ModuleScript → результат require
	self.loading = {}
	self.partsVersion = 0
	self.partsCache = nil
	self.partsCacheVersion = -1
	self.closeHandlers = {}
	self.random = 0
	self:_buildTask()
	self:_buildEnv()

	self.game = self:_new("DataModel")
	self.state[self.game].Name = "Game"
	for _, service in place:GetChildren() do
		self:_convert(service, self.game)
	end
	self.workspace = self.game:GetService("Workspace")
	self.Players = self.game:GetService("Players")
	self.env.game = self.game
	self.env.workspace = self.workspace
	return self
end

--------------------------------------------------------------------------------
-- Планировщик (виртуальное время)
--------------------------------------------------------------------------------

function World:_resume(thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		local message = debug.traceback(thread, tostring(err))
		table.insert(self.errors, message)
		if self.verbose then
			print("[ошибка в потоке] " .. message)
		end
	end
end

function World:_schedule(at: number, thread, args)
	self.seq += 1
	table.insert(self.queue, { time = at, seq = self.seq, thread = thread, args = args })
end

function World:_flushDeferred()
	while #self.deferred > 0 do
		local list = self.deferred
		self.deferred = {}
		for _, job in list do
			if coroutine.status(job.thread) == "suspended" then
				self:_resume(job.thread, table.unpack(job.args, 1, job.args.n))
			end
		end
	end
end

-- Продвинуть время на dt секунд, выполняя всё, что запланировано.
function World:advance(dt: number)
	local target = self.now + dt
	self:_flushDeferred()
	while true do
		local bestIndex, best = nil, nil
		for index, job in self.queue do
			if
				job.time <= target
				and (best == nil or job.time < best.time or (job.time == best.time and job.seq < best.seq))
			then
				bestIndex, best = index, job
			end
		end
		if best == nil then
			break
		end
		table.remove(self.queue, bestIndex)
		self.now = math.max(self.now, best.time)
		if coroutine.status(best.thread) == "suspended" then
			self:_resume(best.thread, table.unpack(best.args, 1, best.args.n))
		end
		self:_flushDeferred()
	end
	self.now = target
end

function World:_buildTask()
	local world = self
	local function toThread(fnOrThread)
		if type(fnOrThread) == "thread" then
			return fnOrThread
		end
		return coroutine.create(fnOrThread)
	end
	self.task = {
		spawn = function(fnOrThread, ...)
			local thread = toThread(fnOrThread)
			world:_resume(thread, ...)
			return thread
		end,
		defer = function(fnOrThread, ...)
			local thread = toThread(fnOrThread)
			table.insert(world.deferred, { thread = thread, args = table.pack(...) })
			return thread
		end,
		delay = function(seconds, fnOrThread, ...)
			local thread = toThread(fnOrThread)
			world:_schedule(world.now + (seconds or 0), thread, table.pack(...))
			return thread
		end,
		wait = function(seconds)
			local thread = coroutine.running()
			local started = world.now
			world:_schedule(world.now + math.max(seconds or 0, 1 / 60), thread, table.pack())
			coroutine.yield()
			return world.now - started
		end,
		cancel = function(thread)
			for index = #world.queue, 1, -1 do
				if world.queue[index].thread == thread then
					table.remove(world.queue, index)
				end
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- Сигналы
--------------------------------------------------------------------------------

function World:_signal()
	local world = self
	local handlers = {}
	local signal = {}
	function signal:Connect(fn)
		local connection = { Connected = true }
		function connection:Disconnect()
			connection.Connected = false
		end
		table.insert(handlers, { fn = fn, connection = connection })
		return connection
	end
	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Wait()
		local thread = coroutine.running()
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			world.task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end
	-- Внутреннее: игра этот метод не вызывает.
	function signal:_fire(...)
		for _, handler in table.clone(handlers) do
			if handler.connection.Connected then
				world.task.spawn(handler.fn, ...)
			end
		end
	end
	function signal:_clear()
		for _, handler in handlers do
			handler.connection.Connected = false
		end
		table.clear(handlers)
	end
	return signal
end

function World:_event(instance, name: string)
	local st = self.state[instance]
	local signal = st.events[name]
	if signal == nil then
		signal = self:_signal()
		st.events[name] = signal
	end
	return signal
end

function World:_tagSignal(kind: string, tag: string)
	local signals = self.tagSignals[kind]
	local signal = signals[tag]
	if signal == nil then
		signal = self:_signal()
		signals[tag] = signal
	end
	return signal
end

--------------------------------------------------------------------------------
-- Экземпляры
--------------------------------------------------------------------------------

local METHODS = {} -- [className] = { [name] = function(world, self, ...) }

local function findInChain(className: string, tableByClass, key)
	local current: string? = className
	while current do
		local entries = tableByClass[current]
		if entries ~= nil and entries[key] ~= nil then
			return entries[key], current
		end
		current = superOf(current)
	end
	return nil, nil
end

function World:_isA(instance, className: string): boolean
	local current: string? = self.state[instance].ClassName
	while current do
		if current == className then
			return true
		end
		current = superOf(current)
	end
	return false
end

function World:_isDescendantOf(instance, ancestor): boolean
	local node = self.state[instance].Parent
	while node do
		if node == ancestor then
			return true
		end
		node = self.state[node].Parent
	end
	return false
end

function World:_inGame(instance): boolean
	return instance == self.game or self:_isDescendantOf(instance, self.game)
end

function World:_descendants(instance, out)
	out = out or {}
	for _, child in self.state[instance].children do
		table.insert(out, child)
		self:_descendants(child, out)
	end
	return out
end

function World:_fireTags(root, kind: string)
	local list = { root }
	self:_descendants(root, list)
	for _, instance in list do
		for tag in self.state[instance].tags do
			local signal = self.tagSignals[kind][tag]
			if signal then
				signal:_fire(instance)
			end
		end
	end
end

function World:_setParent(instance, newParent)
	local st = self.state[instance]
	if newParent ~= nil and self.state[newParent] == nil then
		error("Parent должен быть экземпляром", 3)
	end
	if st.destroyed and newParent ~= nil then
		error(`The Parent property of {st.Name} is locked`, 3)
	end
	if newParent == instance or (newParent and self:_isDescendantOf(newParent, instance)) then
		error("Попытка сделать экземпляр потомком самого себя", 3)
	end
	local old = st.Parent
	if old == newParent then
		return
	end
	local wasInGame = self:_inGame(instance)
	if old then
		local siblings = self.state[old].children
		local index = table.find(siblings, instance)
		if index then
			table.remove(siblings, index)
		end
	end
	st.Parent = newParent
	if newParent then
		table.insert(self.state[newParent].children, instance)
	end
	self.partsVersion += 1
	local nowInGame = self:_inGame(instance)
	if old then
		self:_event(old, "ChildRemoved"):_fire(instance)
	end
	if wasInGame and not nowInGame then
		self:_fireTags(instance, "removed")
	elseif nowInGame and not wasInGame then
		self:_fireTags(instance, "added")
	end
	if newParent then
		self:_event(newParent, "ChildAdded"):_fire(instance)
	end
end

local GETTERS = {
	BasePart = {
		Position = function(_world, self)
			return self.CFrame.Position
		end,
	},
	PVInstance = {
		-- В Roblox у моделей есть скрытое свойство Origin: plot.Origin вернёт CFrame, а не деталь.
		Origin = function(_world, self)
			return self:GetPivot()
		end,
	},
	Humanoid = {
		RootPart = function(world, self)
			local parent = self.Parent
			local root = parent and parent:FindFirstChild("HumanoidRootPart")
			return if root and world:_isA(root, "BasePart") then root else nil
		end,
	},
	Attachment = {
		WorldPosition = function(_world, self)
			return self.Parent.CFrame:PointToWorldSpace(self.CFrame.Position)
		end,
		WorldCFrame = function(_world, self)
			return self.Parent.CFrame * self.CFrame
		end,
	},
}

local SETTERS = {
	Humanoid = {
		-- Здоровье упало до нуля — событие Died (один раз, как в Roblox).
		Health = function(world, self, value)
			local st = world.state[self]
			local old = st.props.Health
			if old == nil then
				old = PROPS.Humanoid.Health
			end
			local maxHealth = st.props.MaxHealth or PROPS.Humanoid.MaxHealth
			local new = math.clamp(value, 0, maxHealth)
			st.props.Health = new
			if old > 0 and new <= 0 then
				world:_event(self, "Died"):_fire()
			end
		end,
	},
	BasePart = {
		Position = function(_world, self, value)
			local cf = self.CFrame
			self.CFrame = cf - cf.Position + value
		end,
	},
}

function World:_new(className: string)
	local world = self
	local proxy = {}
	self.state[proxy] = {
		ClassName = className,
		Name = className,
		Parent = nil,
		children = {},
		props = {},
		attrs = {},
		tags = {},
		events = {},
		attrSignals = {},
		destroyed = false,
	}
	setmetatable(proxy, {
		__index = function(instance, key)
			local st = world.state[instance]
			if key == "Name" then
				return st.Name
			elseif key == "Parent" then
				return st.Parent
			elseif key == "ClassName" then
				return st.ClassName
			end
			local method = findInChain(st.ClassName, METHODS, key)
			if method then
				return function(selfArg, ...)
					if selfArg ~= instance then
						error(`{key}: метод нужно вызывать через двоеточие`, 2)
					end
					return method(world, instance, ...)
				end
			end
			local getter = findInChain(st.ClassName, GETTERS, key)
			if getter then
				return getter(world, instance)
			end
			local value = st.props[key]
			if value ~= nil then
				return value
			end
			local default, owner = findInChain(st.ClassName, PROPS, key)
			if owner ~= nil then
				if default == NIL then
					return nil
				end
				return default
			end
			if EVENTS[key] then
				return world:_event(instance, key)
			end
			for _, child in st.children do
				if world.state[child].Name == key then
					return child
				end
			end
			error(`{key} is not a valid member of {st.ClassName} "{st.Name}"`, 2)
		end,
		__newindex = function(instance, key, value)
			local st = world.state[instance]
			if key == "Parent" then
				world:_setParent(instance, value)
				return
			elseif key == "Name" then
				st.Name = value
				return
			end
			local setter = findInChain(st.ClassName, SETTERS, key)
			if setter then
				setter(world, instance, value)
				return
			end
			local _, owner = findInChain(st.ClassName, PROPS, key)
			if owner == nil then
				error(`{key} is not a valid member of {st.ClassName} "{st.Name}"`, 2)
			end
			st.props[key] = value
		end,
		__tostring = function(instance)
			return world.state[instance].Name
		end,
	})
	return proxy
end

function World:_convert(source, parent)
	local className = source.ClassName
	local instance = self:_new(className)
	local st = self.state[instance]
	st.Name = source.Name
	local current: string? = className
	while current do
		for _, prop in COPY_PROPS[current] or {} do
			local ok, value = pcall(function()
				return source[prop]
			end)
			if ok and value ~= nil then
				st.props[prop] = value
			end
		end
		current = superOf(current)
	end
	for _, tag in source:GetTags() do
		st.tags[tag] = true
	end
	local ok, attributes = pcall(function()
		return source:GetAttributes()
	end)
	if ok then
		for key, value in attributes do
			st.attrs[key] = value
		end
	end
	st.Parent = parent
	table.insert(self.state[parent].children, instance)
	for _, child in source:GetChildren() do
		self:_convert(child, instance)
	end
	return instance
end

function World:_clone(instance, mapping)
	local st = self.state[instance]
	local copy = self:_new(st.ClassName)
	local cst = self.state[copy]
	cst.Name = st.Name
	cst.props = table.clone(st.props)
	cst.attrs = table.clone(st.attrs)
	cst.tags = table.clone(st.tags)
	mapping[instance] = copy
	for _, child in st.children do
		local childCopy = self:_clone(child, mapping)
		self.state[childCopy].Parent = copy
		table.insert(cst.children, childCopy)
	end
	return copy
end

--------------------------------------------------------------------------------
-- Методы классов
--------------------------------------------------------------------------------

METHODS.Instance = {
	FindFirstChild = function(world, self, name, recursive)
		for _, child in world.state[self].children do
			if world.state[child].Name == name then
				return child
			end
		end
		if recursive then
			for _, child in world.state[self].children do
				local found = child:FindFirstChild(name, true)
				if found then
					return found
				end
			end
		end
		return nil
	end,
	FindFirstChildOfClass = function(world, self, className)
		for _, child in world.state[self].children do
			if world.state[child].ClassName == className then
				return child
			end
		end
		return nil
	end,
	FindFirstChildWhichIsA = function(world, self, className, recursive)
		local list = if recursive then world:_descendants(self) else world.state[self].children
		for _, child in list do
			if world:_isA(child, className) then
				return child
			end
		end
		return nil
	end,
	FindFirstAncestorOfClass = function(world, self, className)
		local node = world.state[self].Parent
		while node do
			if world.state[node].ClassName == className then
				return node
			end
			node = world.state[node].Parent
		end
		return nil
	end,
	FindFirstAncestorWhichIsA = function(world, self, className)
		local node = world.state[self].Parent
		while node do
			if world:_isA(node, className) then
				return node
			end
			node = world.state[node].Parent
		end
		return nil
	end,
	WaitForChild = function(_world, self, name)
		return self:FindFirstChild(name)
	end,
	GetChildren = function(world, self)
		return table.clone(world.state[self].children)
	end,
	GetDescendants = function(world, self)
		return world:_descendants(self)
	end,
	IsA = function(world, self, className)
		return world:_isA(self, className)
	end,
	IsDescendantOf = function(world, self, ancestor)
		return world:_isDescendantOf(self, ancestor)
	end,
	IsAncestorOf = function(world, self, descendant)
		return world:_isDescendantOf(descendant, self)
	end,
	GetFullName = function(world, self)
		local names = {}
		local node = self
		while node and node ~= world.game do
			table.insert(names, 1, world.state[node].Name)
			node = world.state[node].Parent
		end
		return table.concat(names, ".")
	end,
	Clone = function(world, self)
		local mapping = {}
		local copy = world:_clone(self, mapping)
		-- Ссылки на экземпляры внутри копии переводим на их копии (PrimaryPart и т. п.).
		for original, cloned in mapping do
			for key, value in world.state[cloned].props do
				if type(value) == "table" and mapping[value] then
					world.state[cloned].props[key] = mapping[value]
				end
			end
			local _ = original
		end
		return copy
	end,
	Destroy = function(world, self)
		local st = world.state[self]
		if st.destroyed then
			return
		end
		world:_event(self, "Destroying"):_fire()
		for _, child in table.clone(st.children) do
			child:Destroy()
		end
		world:_setParent(self, nil)
		st.destroyed = true
		for _, signal in st.events do
			signal:_clear()
		end
	end,
	ClearAllChildren = function(world, self)
		for _, child in table.clone(world.state[self].children) do
			child:Destroy()
		end
	end,
	GetAttribute = function(world, self, name)
		return world.state[self].attrs[name]
	end,
	SetAttribute = function(world, self, name, value)
		world.state[self].attrs[name] = value
		local signal = world.state[self].attrSignals[name]
		if signal then
			signal:_fire()
		end
	end,
	GetAttributes = function(world, self)
		return table.clone(world.state[self].attrs)
	end,
	GetAttributeChangedSignal = function(world, self, name)
		local st = world.state[self]
		local signal = st.attrSignals[name]
		if signal == nil then
			signal = world:_signal()
			st.attrSignals[name] = signal
		end
		return signal
	end,
	GetPropertyChangedSignal = function(world, _self, _name)
		return world:_signal()
	end,
	AddTag = function(world, self, tag)
		world.game:GetService("CollectionService"):AddTag(self, tag)
	end,
	RemoveTag = function(world, self, tag)
		world.game:GetService("CollectionService"):RemoveTag(self, tag)
	end,
	HasTag = function(world, self, tag)
		return world.state[self].tags[tag] == true
	end,
	GetTags = function(world, self)
		local list = {}
		for tag in world.state[self].tags do
			table.insert(list, tag)
		end
		return list
	end,
}

METHODS.PVInstance = {
	GetPivot = function(world, self)
		if world:_isA(self, "BasePart") then
			return self.CFrame
		end
		local primary = self.PrimaryPart
		if primary then
			return primary.CFrame
		end
		return self.WorldPivot
	end,
	PivotTo = function(world, self, target)
		if world:_isA(self, "BasePart") then
			self.CFrame = target
			return
		end
		local delta = target * self:GetPivot():Inverse()
		for _, descendant in world:_descendants(self) do
			if world:_isA(descendant, "BasePart") then
				descendant.CFrame = delta * descendant.CFrame
			end
		end
		world.state[self].props.WorldPivot = delta * self.WorldPivot
	end,
}

METHODS.BasePart = {
	CanSetNetworkOwnership = function(_world, self)
		if self.Anchored then
			return false, "Деталь заякорена"
		end
		return true, nil
	end,
	SetNetworkOwner = function(world, self, owner)
		world.networkOwners[self] = owner or "server"
	end,
}

METHODS.Humanoid = {
	TakeDamage = function(_world, self, amount)
		self.Health = math.max(0, self.Health - amount)
	end,
	MoveTo = function(world, self, position)
		world.state[self].moveTarget = position
	end,
}

METHODS.Player = {
	Kick = function(world, self, message)
		world.kicked[self] = message or ""
		world:removePlayer(self)
	end,
}

METHODS.BaseRemoteEvent = {
	FireClient = function(world, self, player, ...)
		table.insert(world.sent, { remote = self.Name, player = player, args = table.pack(...) })
	end,
	FireAllClients = function(world, self, ...)
		for _, player in world.Players:GetPlayers() do
			table.insert(world.sent, { remote = self.Name, player = player, args = table.pack(...) })
		end
	end,
	FireServer = function()
		error("FireServer вызывается только на клиенте")
	end,
}

METHODS.DataModel = {
	GetService = function(world, self, className)
		for _, child in world.state[self].children do
			if world.state[child].ClassName == className then
				return child
			end
		end
		local service = world:_new(className)
		world.state[service].Name = className
		world.state[service].Parent = self
		table.insert(world.state[self].children, service)
		return service
	end,
	BindToClose = function(world, _self, fn)
		table.insert(world.closeHandlers, fn)
	end,
}

METHODS.Workspace = {
	GetServerTimeNow = function(world)
		return world.baseTime + world.now
	end,
	Raycast = function(world, _self, origin, direction, params)
		return world:_raycast(origin, direction, params)
	end,
}

METHODS.Players = {
	GetPlayers = function(world, self)
		local list = {}
		for _, child in world.state[self].children do
			if world.state[child].ClassName == "Player" then
				table.insert(list, child)
			end
		end
		return list
	end,
	GetPlayerFromCharacter = function(_world, self, character)
		for _, player in self:GetPlayers() do
			if player.Character == character and character ~= nil then
				return player
			end
		end
		return nil
	end,
	GetPlayerByUserId = function(_world, self, userId)
		for _, player in self:GetPlayers() do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end,
}

METHODS.CollectionService = {
	HasTag = function(world, _self, instance, tag)
		return world.state[instance].tags[tag] == true
	end,
	AddTag = function(world, _self, instance, tag)
		local st = world.state[instance]
		if st.tags[tag] then
			return
		end
		st.tags[tag] = true
		if world:_inGame(instance) then
			local signal = world.tagSignals.added[tag]
			if signal then
				signal:_fire(instance)
			end
		end
	end,
	RemoveTag = function(world, _self, instance, tag)
		local st = world.state[instance]
		if not st.tags[tag] then
			return
		end
		st.tags[tag] = nil
		if world:_inGame(instance) then
			local signal = world.tagSignals.removed[tag]
			if signal then
				signal:_fire(instance)
			end
		end
	end,
	GetTags = function(_world, _self, instance)
		return instance:GetTags()
	end,
	GetTagged = function(world, _self, tag)
		local list = {}
		for _, instance in world:_descendants(world.game) do
			if world.state[instance].tags[tag] then
				table.insert(list, instance)
			end
		end
		return list
	end,
	GetInstanceAddedSignal = function(world, _self, tag)
		return world:_tagSignal("added", tag)
	end,
	GetInstanceRemovedSignal = function(world, _self, tag)
		return world:_tagSignal("removed", tag)
	end,
}

METHODS.RunService = {
	IsStudio = function()
		return true
	end,
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
	IsRunning = function()
		return true
	end,
}

METHODS.HttpService = {
	GenerateGUID = function(world, _self, wrap)
		world.random += 1
		local id = string.format("00000000-0000-4000-8000-%012d", world.random)
		return if wrap == false then id else "{" .. id .. "}"
	end,
}

METHODS.DataStoreService = {
	GetDataStore = function()
		error("You must publish this place to the web to access DataStore.")
	end,
}

METHODS.Debris = {
	AddItem = function(world, _self, instance, lifetime)
		world.task.delay(lifetime or 10, function()
			instance:Destroy()
		end)
	end,
}

--------------------------------------------------------------------------------
-- Лучи
--------------------------------------------------------------------------------

local function rayBox(origin, direction, cframe, size)
	local o = cframe:PointToObjectSpace(origin)
	local d = cframe:VectorToObjectSpace(direction)
	local h = size / 2
	-- Луч, начинающийся внутри детали, её не замечает (как в Roblox).
	if math.abs(o.X) <= h.X and math.abs(o.Y) <= h.Y and math.abs(o.Z) <= h.Z then
		return nil
	end
	local tmin, tmax = 0, 1
	for _, axis in { "X", "Y", "Z" } do
		local oa, da, ha = o[axis], d[axis], h[axis]
		if math.abs(da) < 1e-12 then
			if oa < -ha or oa > ha then
				return nil
			end
		else
			local t1, t2 = (-ha - oa) / da, (ha - oa) / da
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

function World:_parts()
	if self.partsCacheVersion ~= self.partsVersion then
		local list = {}
		for _, instance in self:_descendants(self.workspace) do
			if self:_isA(instance, "BasePart") then
				table.insert(list, instance)
			end
		end
		self.partsCache = list
		self.partsCacheVersion = self.partsVersion
	end
	return self.partsCache
end

function World:_raycast(origin, direction, params)
	local filter = if params then params.FilterDescendantsInstances else {}
	local include = params ~= nil and params.FilterType == Enum.RaycastFilterType.Include
	local bestPart, bestT = nil, nil
	for _, part in self:_parts() do
		local props = self.state[part].props
		local canQuery = props.CanQuery
		if canQuery == nil then
			canQuery = true
		end
		if canQuery then
			local listed = false
			for _, entry in filter do
				if part == entry or self:_isDescendantOf(part, entry) then
					listed = true
					break
				end
			end
			if listed == include then
				local t = rayBox(origin, direction, props.CFrame or CFrame.new(), props.Size or PROPS.BasePart.Size)
				if t and (bestT == nil or t < bestT) then
					bestPart, bestT = part, t
				end
			end
		end
	end
	if bestPart == nil then
		return nil
	end
	return {
		Instance = bestPart,
		Position = origin + direction * bestT,
		Distance = direction.Magnitude * bestT,
		Material = bestPart.Material,
	}
end

local function newRaycastParams()
	local data = { FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, IgnoreWater = false }
	local params = {}
	function params:AddToFilter(value)
		local list = data.FilterDescendantsInstances
		-- Массив экземпляров или один экземпляр (rawget: у экземпляра индекс [1] — ошибка).
		if type(value) == "table" and rawget(value, 1) ~= nil then
			for _, item in value do
				table.insert(list, item)
			end
		else
			table.insert(list, value)
		end
	end
	return setmetatable(params, {
		__index = data,
		__newindex = function(_, key, value)
			if key == "FilterDescendantsInstances" then
				data[key] = table.clone(value) -- как в Roblox: массив копируется
			else
				data[key] = value
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- Окружение для кода игры и require
--------------------------------------------------------------------------------

local function newRandom(seed: number?)
	local state = (seed or 1234567) % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	local random = {}
	function random:NextNumber(min, max)
		state = (state * 16807) % 2147483647
		local x = state / 2147483647
		if min ~= nil then
			return min + (max - min) * x
		end
		return x
	end
	function random:NextInteger(min, max)
		return min + math.floor(random:NextNumber() * (max - min + 1))
	end
	function random:NextUnitVector()
		local v = Vector3.new(random:NextNumber() - 0.5, random:NextNumber() - 0.5, random:NextNumber() - 0.5)
		return if v.Magnitude > 1e-9 then v.Unit else Vector3.new(1, 0, 0)
	end
	return random
end

function World:_buildEnv()
	local world = self
	local realTypeof = typeof
	local cframeLib = setmetatable({ lookAt = lookAt }, {
		__index = function(_, key)
			return CFrame[key]
		end,
	})
	self.env = {
		task = self.task,
		os = {
			clock = function()
				return world.now
			end,
			time = function()
				return world.baseTime + math.floor(world.now)
			end,
			date = os.date,
			difftime = os.difftime,
		},
		tick = function()
			return world.baseTime + world.now
		end,
		typeof = function(value)
			if type(value) == "table" and world.state[value] ~= nil then
				return "Instance"
			end
			return realTypeof(value)
		end,
		warn = function(...)
			local parts = table.pack(...)
			for index = 1, parts.n do
				parts[index] = tostring(parts[index])
			end
			local message = table.concat(parts, " ")
			table.insert(world.warnings, message)
			if world.verbose then
				print("[warn] " .. message)
			end
		end,
		print = function(...)
			local parts = table.pack(...)
			for index = 1, parts.n do
				parts[index] = tostring(parts[index])
			end
			table.insert(world.prints, table.concat(parts, " "))
		end,
		require = function(module)
			return world:_require(module)
		end,
		Instance = {
			new = function(className, parent)
				local instance = world:_new(className)
				if parent then
					instance.Parent = parent
				end
				return instance
			end,
		},
		Vector3 = Vector3,
		CFrame = cframeLib,
		Color3 = Color3,
		Enum = Enum,
		UDim = UDim,
		UDim2 = UDim2,
		Random = { new = newRandom },
		RaycastParams = { new = newRaycastParams },
	}
end

function World:_load(scriptInstance)
	local env = table.clone(self.env)
	env.script = scriptInstance
	local chunk = luau.load(scriptInstance.Source, {
		debugName = scriptInstance:GetFullName(),
		environment = env,
	})
	return chunk
end

function World:_require(module)
	if type(module) ~= "table" or self.state[module] == nil or not self:_isA(module, "ModuleScript") then
		error("require: ожидался ModuleScript", 3)
	end
	local cached = self.modules[module]
	if cached ~= nil then
		return cached.value
	end
	if self.loading[module] then
		error(`require: циклическая зависимость через {module:GetFullName()}`, 3)
	end
	self.loading[module] = true
	local chunk = self:_load(module)
	local value = chunk()
	self.loading[module] = nil
	self.modules[module] = { value = value }
	return value
end

-- Запустить серверные скрипты (как при старте сервера).
function World:start()
	local serverScripts = self.game:GetService("ServerScriptService")
	for _, instance in serverScripts:GetDescendants() do
		if self.state[instance].ClassName == "Script" then
			self.task.spawn(self:_load(instance))
		end
	end
	self:advance(0)
end

-- Модуль игры по пути: world:module("ServerScriptService.Server.Services.DataService").
function World:module(path: string)
	local node = self.game
	for name in string.gmatch(path, "[^%.]+") do
		node = if node == self.game then self.game:GetService(name) else node:FindFirstChild(name)
		assert(node, `нет экземпляра {path}`)
	end
	return self:_require(node)
end

--------------------------------------------------------------------------------
-- Игроки
--------------------------------------------------------------------------------

function World:addPlayer(name: string, userId: number)
	local player = self:_new("Player")
	self.state[player].Name = name
	player.UserId = userId
	player.DisplayName = name
	local backpack = self:_new("Folder")
	self.state[backpack].Name = "Backpack"
	backpack.Parent = player
	player.Parent = self.Players
	self.Players.PlayerAdded:_fire(player)
	self:_flushDeferred()
	self:spawnCharacter(player)
	return player
end

function World:spawnCharacter(player)
	local respawn = player.RespawnLocation
	local position
	if respawn then
		position = respawn.Position + Vector3.new(0, 3, 0)
	else
		local lobby = self.workspace:FindFirstChild("LobbySpawn")
		position = if lobby then lobby.Position + Vector3.new(0, 3, 0) else Vector3.new(0, 3, 0)
	end
	local old = player.Character
	if old then
		old:Destroy()
	end
	local character = self:_new("Model")
	self.state[character].Name = player.Name
	local humanoid = self:_new("Humanoid")
	humanoid.Parent = character
	local root = self:_new("Part")
	self.state[root].Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position)
	root.Parent = character
	local head = self:_new("Part")
	self.state[head].Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0))
	head.Parent = character
	character.PrimaryPart = root
	character.Parent = self.workspace
	player.Character = character
	player.CharacterAdded:_fire(character)
	self:_flushDeferred()
	return character
end

function World:removePlayer(player)
	if player.Parent ~= self.Players then
		return
	end
	self.Players.PlayerRemoving:_fire(player)
	local character = player.Character
	player.Parent = nil
	if character then
		character:Destroy()
	end
	self:_flushDeferred()
end

-- Переместить персонажа (позиция корня; голова на 1,5 выше).
-- Телепорт по воле сервера (через MovementService:teleport, как делает сама игра).
-- Для подготовки сцены в тестах.
function World:moveTo(player, position)
	local movement = self:module("ServerScriptService.Server.Services.MovementService")
	movement:teleport(player, CFrame.new(position))
end

-- Перемещение «от клиента»: персонаж просто оказался в новой точке.
-- Так выглядит и честная ходьба, и телепорт из эксплойта — проверяет MovementService.
function World:rawMove(player, position)
	local character = player.Character
	character.HumanoidRootPart.CFrame = CFrame.new(position)
	character.Head.CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0))
end

function World:humanoid(player)
	return player.Character and player.Character:FindFirstChildOfClass("Humanoid")
end

-- Взять в руки оружие из рюкзака (по WeaponId или первое попавшееся).
function World:equip(player, weaponId: string?)
	local current = player.Character:FindFirstChildWhichIsA("Tool")
	if current then
		current.Parent = player.Backpack
	end
	local tool = nil
	for _, child in player.Backpack:GetChildren() do
		if self:_isA(child, "Tool") and (weaponId == nil or child:GetAttribute("WeaponId") == weaponId) then
			tool = child
			break
		end
	end
	assert(tool, `в рюкзаке нет оружия {weaponId or ""}`)
	tool.Parent = player.Character
	self:_flushDeferred()
	return tool
end

-- Направление от головы игрока к точке (для события Fire).
function World:aimAt(player, target)
	return (target - player.Character.Head.Position).Unit
end

function World:unequip(player)
	local tool = player.Character and player.Character:FindFirstChildWhichIsA("Tool")
	if tool then
		tool.Parent = player.Backpack
	end
	self:_flushDeferred()
end

-- Сообщение в чат (чат-команды DevCommandsService).
function World:chat(player, text: string)
	local alias = string.match(text, "^(%S+)")
	for _, instance in self.game:GetService("TextChatService"):GetDescendants() do
		if self.state[instance].ClassName == "TextChatCommand" and instance.PrimaryAlias == alias then
			instance.Triggered:_fire({ UserId = player.UserId, Name = player.Name }, text)
			self:_flushDeferred()
			return
		end
	end
	error(`нет чат-команды {alias}`)
end

-- Событие клиент → сервер, как будто его отправил клиент игрока.
function World:fireServer(player, remoteName: string, ...)
	local remote = self.game:GetService("ReplicatedStorage").Remotes:FindFirstChild(remoteName)
	assert(remote, `нет события {remoteName}`)
	remote.OnServerEvent:_fire(player, ...)
	self:_flushDeferred()
end

-- Сработала подсказка ProximityPrompt у игрока.
function World:trigger(player, prompt)
	prompt.Triggered:_fire(player)
	self:_flushDeferred()
end

-- Все события сервер → клиент для игрока (по имени события).
function World:received(player, remoteName: string)
	local list = {}
	for _, event in self.sent do
		if event.player == player and event.remote == remoteName then
			table.insert(list, event.args)
		end
	end
	return list
end

-- Тексты уведомлений игроку.
function World:notifications(player)
	local list = {}
	for _, args in self:received(player, "Notify") do
		table.insert(list, args[1])
	end
	return list
end

function World:hasNotification(player, fragment: string): boolean
	for _, text in self:notifications(player) do
		if string.find(text, fragment, 1, true) then
			return true
		end
	end
	return false
end

function World:hasWarning(fragment: string): boolean
	for _, text in self.warnings do
		if string.find(text, fragment, 1, true) then
			return true
		end
	end
	return false
end

-- Точка в системе координат участка (от Plot.Origin).
function World:plotPoint(plotModel, x: number, y: number, z: number)
	return plotModel:FindFirstChild("Origin").CFrame:PointToWorldSpace(Vector3.new(x, y, z))
end

function World:plot(index: number)
	return self.workspace.Plots:FindFirstChild("Plot" .. index)
end

-- Деталь с тегом внутри экземпляра.
function World:findTagged(root, tag: string)
	for _, instance in self:_descendants(root) do
		if self.state[instance].tags[tag] then
			return instance
		end
	end
	return nil
end

function World:findPrompt(registerPart, role: string)
	for _, child in self.state[registerPart].children do
		if self.state[child].ClassName == "ProximityPrompt" and child:GetAttribute("Role") == role then
			return child
		end
	end
	return nil
end

World.Vector3 = Vector3
World.CFrame = CFrame
World.lookAt = lookAt

return World
