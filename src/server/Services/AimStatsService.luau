--!strict
--[[
	AimStatsService — статистика стрельбы против аимбота.

	Направление выстрела присылает клиент, поэтому идеальную наводку сервер
	запретить не может. Зато он видит её след: «резкую доводку с попаданием».
	Это пара соседних выстрелов, где:
	  • оба ранили врагов не ближе MIN_DISTANCE,
	  • второй повёрнут от первого на SNAP_ANGLE и больше,
	  • второй сделан не позже SNAP_TIME после первого.
	То есть «попал в одного — мгновенно развернулся — попал в другого».
	Человек так иногда делает, но редко. Аимбот, переключаясь между целями,
	делает это постоянно. Промах в пустоту и поворот на цель — обычное дело,
	это не считается. SNAP_LIMIT таких выстрелов за WINDOW секунд —
	подозрение: запись в лог и очки подозрительности (NetService:flag).
	Два подозрения подряд набирают порог кика.

	Ограничения (честно):
	• «Плавный» аимбот, который поворачивает прицел постепенно, не ловится.
	• Снайперская винтовка стреляет раз в 1,5 с — по выстрелам её доводку
	  не отличить от обычного поворота.
	Поэтому это не приговор, а сигнал: лог для модераторов и кик только
	за повторяющийся, очевидный паттерн.
]]

local Players = game:GetService("Players")

local NetService = require(script.Parent.NetService)

local SNAP_ANGLE = 60 -- градусов между соседними выстрелами
local SNAP_TIME = 0.35 -- секунд между ними (темп пистолета 0,3 с, автомата 0,12 с)
local MIN_DISTANCE = 12 -- вблизи большие повороты естественны
local WINDOW = 60 -- секунд
local SNAP_LIMIT = 4 -- доводок с попаданием за окно
local PENALTY = 30 -- очки подозрительности за одно подозрение (кик — от 50, гаснут 0,5 в секунду)

export type Stats = {
	shots: number,
	playerHits: number,
	snapHits: number, -- всего за сессию
	suspicions: number,
}

type State = {
	stats: Stats,
	lastDirection: Vector3?,
	lastShotAt: number,
	lastWasHit: boolean, -- предыдущий выстрел ранил врага не ближе MIN_DISTANCE
	recentSnaps: { number }, -- время доводок в окне
}

local AimStatsService = {}

local states: { [Player]: State } = {}

local function stateOf(player: Player): State
	local state = states[player]
	if state == nil then
		state = {
			stats = { shots = 0, playerHits = 0, snapHits = 0, suspicions = 0 },
			lastDirection = nil,
			lastShotAt = -math.huge,
			lastWasHit = false,
			recentSnaps = {},
		}
		states[player] = state
	end
	return state
end

local function angleBetween(a: Vector3, b: Vector3): number
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

-- Учесть выстрел. direction — направление, которое прислал клиент (до разброса);
-- hitDistance — расстояние до раненого врага (nil — во врага не попал).
function AimStatsService:record(player: Player, direction: Vector3, hitDistance: number?)
	local state = stateOf(player)
	local stats = state.stats
	local now = os.clock()
	stats.shots += 1
	if hitDistance then
		stats.playerHits += 1
	end

	local farHit = hitDistance ~= nil and hitDistance >= MIN_DISTANCE
	local previous = state.lastDirection
	local isSnap = previous ~= nil
		and farHit
		and state.lastWasHit
		and now - state.lastShotAt <= SNAP_TIME
		and angleBetween(previous, direction) >= SNAP_ANGLE
	state.lastDirection = direction
	state.lastShotAt = now
	state.lastWasHit = farHit
	if not isSnap then
		return
	end

	stats.snapHits += 1
	local recent = state.recentSnaps
	table.insert(recent, now)
	while recent[1] and now - recent[1] > WINDOW do
		table.remove(recent, 1)
	end
	if #recent >= SNAP_LIMIT then
		stats.suspicions += 1
		NetService:flag(
			player,
			`подозрение на аимбот: {#recent} резких доводок с попаданием за {WINDOW} с `
				.. `(всего выстрелов {stats.shots}, попаданий {stats.playerHits})`,
			PENALTY
		)
		table.clear(recent)
	end
end

-- Статистика игрока за сессию (для модераторов и тестов).
function AimStatsService:getStats(player: Player): Stats
	return table.clone(stateOf(player).stats)
end

function AimStatsService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
	end)
end

return AimStatsService
