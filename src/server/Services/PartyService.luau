--!strict
--[[
	PartyService — группы для совместных рейдов (до MAX_SIZE игроков).

	• Пригласить (InviteToParty), ответить (RespondPartyInvite), выйти (LeaveParty).
	  Размер группы и срок приглашения — Config/Party.
	• Союзники не ранят друг друга (пули, взрывы), охрана союзника не трогает
	  союзника, кассу союзника нельзя взломать (PlotService:isFriendly).
	• Состав группы рассылается участникам событием PartyUpdate(userIds).

	ЗАЩИТА:
	• Принять можно только существующее и не просроченное приглашение именно
	  этому игроку; состав и размер группы проверяет сервер.
	• Частота приглашений ограничена (NetService), поэтому спамить
	  приглашениями нельзя.
	• «Удар в спину»: вышедший из группы ещё LeaveGrace секунд считается
	  союзником бывшей группы. Владелец успевает увидеть «X покинул группу»,
	  а охрана — развернуться.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Guard = require(ReplicatedStorage.Shared.Guard)
local PartyConfig = require(ReplicatedStorage.Shared.Config.Party)
local NetService = require(script.Parent.NetService)

-- UserId: в Studio у тестовых игроков (Test → Clients and Servers) он
-- отрицательный (-1, -2…), поэтому принимаем любое целое. Существует ли такой
-- игрок, сервер всё равно проверяет сам (GetPlayerByUserId).
local USER_ID = Guard.integer(-2 ^ 53, 2 ^ 53)

local MAX_SIZE = PartyConfig.MaxSize
local INVITE_TTL = PartyConfig.InviteTtl
local LEAVE_GRACE = PartyConfig.LeaveGrace

type Party = { members: { Player } }
type Former = { allies: { Player }, untilTime: number }

local PartyService = {}

local partyOf: { [Player]: Party } = {}
local invites: { [Player]: { [Player]: number } } = {} -- приглашённый → пригласивший → срок (os.clock)
local formerAllies: { [Player]: Former } = {} -- вышедший → с кем был, до какого времени

local function memberIds(party: Party): { number }
	local ids = {}
	for _, member in party.members do
		table.insert(ids, member.UserId)
	end
	return ids
end

local function broadcast(party: Party)
	local ids = memberIds(party)
	for _, member in party.members do
		NetService:fireClient(member, "PartyUpdate", ids)
	end
end

local function notifyParty(party: Party, text: string)
	for _, member in party.members do
		NetService:notify(member, text)
	end
end

--------------------------------------------------------------------------------
-- Публичный API
--------------------------------------------------------------------------------

local function wasAllyOf(leaver: Player, other: Player): boolean
	local former = formerAllies[leaver]
	return former ~= nil and former.untilTime > os.clock() and table.find(former.allies, other) ~= nil
end

-- Союзники ли игроки (один и тот же игрок — тоже «союзник»).
function PartyService:areAllies(a: Player, b: Player): boolean
	if a == b then
		return true
	end
	local party = partyOf[a]
	if party ~= nil and partyOf[b] == party then
		return true
	end
	return wasAllyOf(a, b) or wasAllyOf(b, a)
end

-- Состоит ли игрок в группе (без учёта LeaveGrace).
function PartyService:inParty(player: Player): boolean
	return partyOf[player] ~= nil
end

function PartyService:getMembers(player: Player): { Player }
	local party = partyOf[player]
	return if party then table.clone(party.members) else { player }
end

function PartyService:invite(inviter: Player, target: Player): boolean
	if target == inviter or target.Parent ~= Players then
		return false
	end
	if PartyService:areAllies(inviter, target) then
		NetService:notify(inviter, `{target.DisplayName} уже в вашей группе`)
		return false
	end
	if partyOf[target] then
		NetService:notify(inviter, `{target.DisplayName} уже в другой группе`)
		return false
	end
	local party = partyOf[inviter]
	if party and #party.members >= MAX_SIZE then
		NetService:notify(inviter, `В группе уже {MAX_SIZE} игрока`)
		return false
	end
	local pending = invites[target]
	if pending == nil then
		pending = {}
		invites[target] = pending
	end
	pending[inviter] = os.clock() + INVITE_TTL
	NetService:fireClient(target, "PartyInvite", inviter.UserId, inviter.DisplayName)
	NetService:notify(target, `{inviter.DisplayName} зовёт вас в группу`)
	NetService:notify(inviter, `Приглашение отправлено: {target.DisplayName}`)
	return true
end

function PartyService:respond(target: Player, inviter: Player, accept: boolean): boolean
	local pending = invites[target]
	local expiresAt = if pending then pending[inviter] else nil
	if pending == nil or expiresAt == nil or expiresAt < os.clock() then
		NetService:notify(target, "Приглашение устарело")
		return false
	end
	pending[inviter] = nil
	if not accept then
		NetService:notify(inviter, `{target.DisplayName} отказался от группы`)
		return false
	end
	if partyOf[target] then
		NetService:notify(target, "Сначала выйдите из своей группы")
		return false
	end
	if inviter.Parent ~= Players then
		return false
	end

	local party = partyOf[inviter]
	if party == nil then
		party = { members = { inviter } }
		partyOf[inviter] = party
	end
	if #party.members >= MAX_SIZE then
		NetService:notify(target, "Группа уже полная")
		return false
	end
	table.insert(party.members, target)
	partyOf[target] = party
	broadcast(party)
	notifyParty(party, `{target.DisplayName} теперь в группе`)
	return true
end

function PartyService:leave(player: Player)
	local party = partyOf[player]
	if party == nil then
		return
	end
	partyOf[player] = nil
	local index = table.find(party.members, player)
	if index then
		table.remove(party.members, index)
	end
	formerAllies[player] = { allies = table.clone(party.members), untilTime = os.clock() + LEAVE_GRACE }
	if player.Parent == Players then
		NetService:fireClient(player, "PartyUpdate", {})
	end
	if #party.members == 1 then
		-- Остался один — группа распадается.
		local last = party.members[1]
		partyOf[last] = nil
		table.clear(party.members)
		NetService:fireClient(last, "PartyUpdate", {})
		NetService:notify(last, "Группа распалась")
	elseif #party.members > 1 then
		broadcast(party)
		notifyParty(party, `{player.DisplayName} покинул группу`)
	end
end

--------------------------------------------------------------------------------
-- Жизненный цикл
--------------------------------------------------------------------------------

function PartyService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		PartyService:leave(player)
		invites[player] = nil
		formerAllies[player] = nil
		for _, pending in invites do
			pending[player] = nil
		end
	end)

	NetService:on("InviteToParty", {
		args = { USER_ID },
		rate = 1,
		burst = 3,
	}, function(player: Player, userId: number)
		local target = Players:GetPlayerByUserId(userId)
		if target == nil then
			NetService:notify(player, "Такого игрока нет на сервере")
			return
		end
		PartyService:invite(player, target)
	end)
	NetService:on("RespondPartyInvite", {
		args = { USER_ID, Guard.boolean() },
		rate = 2,
		burst = 4,
	}, function(player: Player, inviterId: number, accept: boolean)
		local inviter = Players:GetPlayerByUserId(inviterId)
		if inviter then
			PartyService:respond(player, inviter, accept)
		end
	end)
	NetService:on("LeaveParty", { args = {}, rate = 1, burst = 2 }, function(player: Player)
		PartyService:leave(player)
	end)
end

return PartyService
