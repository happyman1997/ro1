--!strict
--[[
	RateLimiter — ограничитель частоты запросов по алгоритму «ведро токенов».

	У каждого игрока ведро на `burst` токенов, которое пополняется со скоростью
	`rate` токенов в секунду. Каждый запрос тратит один токен; пустое ведро —
	запрос отклоняется. Короткие всплески (лаг, двойной клик) проходят,
	а флуд из эксплойта — нет.

	Пример:
		local limiter = RateLimiter.new(2, 5) -- в среднем 2 запроса/с, подряд до 5
		if not limiter:check(player) then return end
		...
		Players.PlayerRemoving:Connect(function(p) limiter:remove(p) end)
]]

export type RateLimiter = {
	check: (self: RateLimiter, player: Player) -> boolean,
	remove: (self: RateLimiter, player: Player) -> (),
}

type Bucket = { tokens: number, updatedAt: number }

type RateLimiterImpl = {
	rate: number,
	burst: number,
	buckets: { [Player]: Bucket },
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(rate: number, burst: number?): RateLimiter
	assert(rate > 0, "RateLimiter: rate должен быть больше 0")
	local self: RateLimiterImpl = {
		rate = rate,
		burst = math.max(1, burst or rate),
		buckets = {},
	}
	return (setmetatable(self, RateLimiter) :: any) :: RateLimiter
end

-- true — запрос разрешён (токен списан), false — слишком часто.
function RateLimiter.check(self: RateLimiterImpl, player: Player): boolean
	local now = os.clock()
	local bucket = self.buckets[player]
	if bucket == nil then
		bucket = { tokens = self.burst, updatedAt = now }
		self.buckets[player] = bucket
	else
		bucket.tokens = math.min(self.burst, bucket.tokens + (now - bucket.updatedAt) * self.rate)
		bucket.updatedAt = now
	end

	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Забыть игрока (вызывать при выходе, чтобы не копить память).
function RateLimiter.remove(self: RateLimiterImpl, player: Player)
	self.buckets[player] = nil
end

return RateLimiter
