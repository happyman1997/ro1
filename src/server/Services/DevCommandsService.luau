--!strict
--[[
	DevCommandsService — чат-команды для проверки механик. ТОЛЬКО В STUDIO.

	В опубликованной игре команды не создаются вообще: RunService:IsStudio()
	на живом сервере всегда false. Игроки воспользоваться ими не смогут,
	даже подделав сообщение в чате.
	Команды вызывают те же методы сервисов, что и Remote, со всеми проверками
	(например, /upgrade не сработает без денег или во время атаки).

	/help             список команд
	/cash <сумма>     добавить денег на кошелёк
	/upgrade          улучшить ресторан
	/repair           починить ресторан
	/class <класс>    сменить класс (на своей территории)
	/weapon <оружие>  получить оружие (Pistol, Rifle, Sniper)
	/slots            слоты охраны в своём ресторане
	/hire <слот> <тип> нанять охрану (Bouncer, Gunner, CeilingTurret)
	/dismiss <слот>   уволить охрану
	/buy <оружие>     купить оружие за Cash (как в магазине)
	/fill             заполнить свою кассу до предела
	/break            сломать мебель в своём ресторане
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Classes = require(ReplicatedStorage.Shared.Config.Classes)
local Tiers = require(ReplicatedStorage.Shared.Config.Tiers)
local CashRegisterService = require(script.Parent.CashRegisterService)
local ClassService = require(script.Parent.ClassService)
local DefenseService = require(script.Parent.DefenseService)
local Defense = require(ReplicatedStorage.Shared.Config.Defense)
local DataService = require(script.Parent.DataService)
local NetService = require(script.Parent.NetService)
local PlotService = require(script.Parent.PlotService)
local RestaurantService = require(script.Parent.RestaurantService)
local ShopService = require(script.Parent.ShopService)
local WeaponService = require(script.Parent.WeaponService)
local Weapons = require(ReplicatedStorage.Shared.Config.Weapons)

local MAX_CASH_PER_COMMAND = 1_000_000

type Command = {
	usage: string,
	run: (player: Player, args: { string }) -> (),
}

local DevCommandsService = {}

local function sortedKeys(dictionary: { [string]: any }): { string }
	local keys = {}
	for key in dictionary do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local commands: { [string]: Command } = {}

commands.help = {
	usage = "/help — этот список",
	run = function(player: Player)
		local lines = {}
		for _, name in sortedKeys(commands) do
			table.insert(lines, commands[name].usage)
		end
		NetService:notify(player, table.concat(lines, "\n"))
	end,
}

commands.cash = {
	usage = "/cash <сумма> — добавить денег",
	run = function(player: Player, args: { string })
		local amount = tonumber(args[1])
		if amount == nil or amount ~= amount or amount < 1 or amount > MAX_CASH_PER_COMMAND then
			NetService:notify(player, `Укажите сумму от 1 до {MAX_CASH_PER_COMMAND}`)
			return
		end
		DataService:increment(player, "Cash", math.floor(amount))
	end,
}

commands.upgrade = {
	usage = "/upgrade — улучшить ресторан",
	run = function(player: Player)
		PlotService:upgrade(player)
	end,
}

commands.repair = {
	usage = "/repair — починить ресторан",
	run = function(player: Player)
		RestaurantService:repair(player)
	end,
}

commands.class = {
	usage = `/class <{table.concat(sortedKeys(Classes), "|")}> — сменить класс`,
	run = function(player: Player, args: { string })
		local classId = args[1]
		if classId == nil or Classes[classId] == nil then
			NetService:notify(player, `Классы: {table.concat(sortedKeys(Classes), ", ")}`)
			return
		end
		ClassService:selectClass(player, classId)
	end,
}

commands.weapon = {
	usage = `/weapon <{table.concat(sortedKeys(Weapons), "|")}> — получить оружие`,
	run = function(player: Player, args: { string })
		local weaponId = args[1]
		if weaponId == nil or Weapons[weaponId] == nil then
			NetService:notify(player, `Оружие: {table.concat(sortedKeys(Weapons), ", ")}`)
			return
		end
		if WeaponService:giveWeapon(player, weaponId) then
			NetService:notify(player, `Получено: {Weapons[weaponId].Name}`)
		end
	end,
}

commands.slots = {
	usage = "/slots — слоты охраны в своём ресторане",
	run = function(player: Player)
		local lines = {}
		for _, slot in DefenseService:getSlots(player) do
			table.insert(lines, `{slot.id} ({slot.kind}): {slot.occupant or "свободно"}`)
		end
		NetService:notify(player, if #lines > 0 then table.concat(lines, "\n") else "Слотов нет")
	end,
}

commands.hire = {
	usage = `/hire <слот> <{table.concat(sortedKeys(Defense), "|")}> — нанять охрану`,
	run = function(player: Player, args: { string })
		local slotId, defenderType = args[1], args[2]
		if slotId == nil or defenderType == nil or Defense[defenderType] == nil then
			NetService:notify(
				player,
				`Пример: /hire Door1 Bouncer. Типы: {table.concat(sortedKeys(Defense), ", ")}`
			)
			return
		end
		DefenseService:hire(player, slotId, defenderType)
	end,
}

commands.dismiss = {
	usage = "/dismiss <слот> — уволить охрану",
	run = function(player: Player, args: { string })
		if args[1] == nil then
			NetService:notify(player, "Пример: /dismiss Door1")
			return
		end
		DefenseService:dismiss(player, args[1])
	end,
}

commands.buy = {
	usage = `/buy <{table.concat(sortedKeys(Weapons), "|")}> — купить оружие за Cash`,
	run = function(player: Player, args: { string })
		local weaponId = args[1]
		if weaponId == nil or Weapons[weaponId] == nil then
			NetService:notify(player, `Оружие: {table.concat(sortedKeys(Weapons), ", ")}`)
			return
		end
		ShopService:buyWeapon(player, weaponId)
	end,
}

commands.fill = {
	usage = "/fill — заполнить свою кассу",
	run = function(player: Player)
		local plot = PlotService:getPlot(player)
		if plot == nil then
			NetService:notify(player, "У вас нет участка")
			return
		end
		CashRegisterService:deposit(plot, Tiers[plot.tier].RegisterCapacity)
		NetService:notify(player, "Касса заполнена")
	end,
}

commands["break"] = {
	usage = "/break — сломать мебель в своём ресторане",
	run = function(player: Player)
		local plot = PlotService:getPlot(player)
		local restaurant = if plot then plot.restaurant else nil
		if restaurant == nil then
			NetService:notify(player, "У вас нет ресторана")
			return
		end
		for _, descendant in restaurant:GetDescendants() do
			if CollectionService:HasTag(descendant, "Furniture") and descendant:GetAttribute("Broken") ~= true then
				descendant:SetAttribute("Broken", true)
				if descendant:IsA("BasePart") then
					local part = descendant :: BasePart
					part.Color = Color3.fromRGB(60, 60, 60)
				end
				NetService:notify(
					player,
					"Мебель сломана: через пару секунд ресторан остановится"
				)
				return
			end
		end
		NetService:notify(player, "Ломать больше нечего")
	end,
}

function DevCommandsService:Start()
	if not RunService:IsStudio() then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "DevCommands"
	for name, command in commands do
		local textCommand = Instance.new("TextChatCommand")
		textCommand.Name = name
		textCommand.PrimaryAlias = "/" .. name
		textCommand.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player == nil then
				return
			end
			local args = {}
			for word in string.gmatch(text, "%S+") do
				table.insert(args, word)
			end
			table.remove(args, 1) -- первое слово — сама команда
			command.run(player, args)
		end)
		textCommand.Parent = folder
	end
	folder.Parent = TextChatService

	print("[DevCommands] Чат-команды для тестов в Studio включены, список: /help")
end

return DevCommandsService
