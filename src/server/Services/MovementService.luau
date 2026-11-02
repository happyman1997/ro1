--!strict
--[[
	MovementService — серверная проверка перемещения (против телепорта и спидхака).

	Персонажем управляет клиент (сетевое владение), поэтому позицию присылает он.
	Раз в CHECK_INTERVAL секунд сервер сравнивает новую позицию с прошлой:
	• по горизонтали путь расходуется из «запаса пути». Запас пополняется со
	  скоростью WalkSpeed × SPEED_TOLERANCE (WalkSpeed — серверное значение:
	  подмена на клиенте не реплицируется) и копится не больше чем на
	  BUDGET_SECONDS секунд. Так честный игрок после лага не страдает, а
	  телепорт и спидхак упираются в пустой запас;
	• вверх — не быстрее MAX_RISE_SPEED (с запасом на прыжок). Падение вниз не ограничено.
	Нарушение → персонаж возвращается на последнюю честную позицию, анти-чит
	получает отметку (повторяющиеся нарушения приводят к кику).

	Телепорт по воле сервера (выдача участка и т. п.) делается только через
	MovementService:teleport — он сбрасывает отсчёт.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local NetService = require(script.Parent.NetService)

local CHECK_INTERVAL = 0.25
local SPEED_TOLERANCE = 1.4 -- +40% к скорости ходьбы: склоны, рассинхрон, погрешность
local BUDGET_SECONDS = 1.5 -- сколько секунд пути можно «накопить» (лаг, задержка пакетов)
local MAX_RISE_SPEED = 60 -- студов в секунду вверх
local RISE_ALLOWANCE = 10 -- запас по высоте за одну проверку (прыжок)

type Track = { position: Vector3, valid: CFrame, budget: number, checkedAt: number }

local MovementService = {}

local tracks: { [Player]: Track } = {}

local function reset(player: Player, cframe: CFrame)
	tracks[player] = { position = cframe.Position, valid = cframe, budget = 0, checkedAt = os.clock() }
end

-- Телепортировать персонажа по воле сервера (без срабатывания проверки).
function MovementService:teleport(player: Player, cframe: CFrame)
	local character = player.Character
	if character == nil then
		return
	end
	character:PivotTo(cframe)
	local root = character:FindFirstChild("HumanoidRootPart")
	reset(player, if root and root:IsA("BasePart") then (root :: BasePart).CFrame else cframe)
end

local function check()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character, humanoid, root = CharacterUtil.getAlive(player)
		if character == nil or humanoid == nil or root == nil then
			continue
		end
		local track = tracks[player]
		if track == nil then
			reset(player, root.CFrame)
			continue
		end

		local dt = now - track.checkedAt
		track.checkedAt = now
		local speed = humanoid.WalkSpeed * SPEED_TOLERANCE
		track.budget = math.min(speed * BUDGET_SECONDS, track.budget + speed * dt)

		local delta = root.Position - track.position
		local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
		local rise = math.max(0, delta.Y)
		if horizontal > track.budget or rise > MAX_RISE_SPEED * dt + RISE_ALLOWANCE then
			character:PivotTo(track.valid) -- назад на последнюю честную позицию
			NetService:flag(
				player,
				`слишком быстрое перемещение ({math.floor(horizontal)} студов за {math.floor(
					dt * 100
				) / 100} с)`,
				NetService.Penalty.RateLimit
			)
		else
			track.budget -= horizontal
			track.position = root.Position
			track.valid = root.CFrame
		end
	end
end

function MovementService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			tracks[player] = nil -- новый персонаж — новый отсчёт с точки появления
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			tracks[player] = nil
		end)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		tracks[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			xpcall(check, function(message: any)
				warn(
					`[MovementService] Ошибка проверки перемещения: {message}\n{debug.traceback()}`
				)
			end)
		end
	end)
end

return MovementService
