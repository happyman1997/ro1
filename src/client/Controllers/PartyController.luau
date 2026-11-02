--!strict
--[[
	PartyController — группа на клиенте: состав, входящие приглашения,
	подсветка союзников.

	Состав присылает сервер (PartyUpdate), приглашения — PartyInvite.
	Подсветка союзников — только подсказка «свой/чужой» для глаз:
	кого можно ранить, всё равно решает сервер (PartyService:areAllies).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PartyConfig = require(Shared:WaitForChild("Config"):WaitForChild("Party"))
local Signal = require(Shared:WaitForChild("Signal"))
local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

local localPlayer = Players.LocalPlayer

local ALLY_COLOR = Color3.fromRGB(90, 220, 120)
local HIGHLIGHT_NAME = "AllyHighlight"

export type Invite = { userId: number, name: string, expiresAt: number }

local PartyController = {}

-- Состав группы или приглашения изменились.
PartyController.Changed = Signal.new() :: Signal.Signal<()>

local members: { number } = {}
local invites: { [number]: Invite } = {}

function PartyController:getMembers(): { number }
	return table.clone(members)
end

function PartyController:isAlly(userId: number): boolean
	return userId ~= localPlayer.UserId and table.find(members, userId) ~= nil
end

-- Действующие приглашения, по порядку прихода.
function PartyController:getInvites(): { Invite }
	local now = os.clock()
	local list = {}
	for userId, invite in invites do
		if invite.expiresAt <= now or Players:GetPlayerByUserId(userId) == nil then
			invites[userId] = nil
		else
			table.insert(list, invite)
		end
	end
	table.sort(list, function(a, b)
		return a.expiresAt < b.expiresAt
	end)
	return list
end

function PartyController:invite(userId: number)
	Net.fire("InviteToParty", userId)
end

function PartyController:respond(userId: number, accept: boolean)
	invites[userId] = nil
	Net.fire("RespondPartyInvite", userId, accept)
	PartyController.Changed:Fire()
end

function PartyController:leave()
	Net.fire("LeaveParty")
end

--------------------------------------------------------------------------------
-- Подсветка союзников
--------------------------------------------------------------------------------

local function setHighlight(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	local existing = character:FindFirstChild(HIGHLIGHT_NAME)
	local ally = PartyController:isAlly(player.UserId)
	if ally and existing == nil then
		local effect = Instance.new("Highlight")
		effect.Name = HIGHLIGHT_NAME
		effect.FillTransparency = 1 -- только контур, чтобы не мешать целиться
		effect.OutlineColor = ALLY_COLOR
		effect.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		effect.Parent = character
	elseif not ally and existing then
		existing:Destroy()
	end
end

local function refreshHighlights()
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			setHighlight(player)
		end
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		setHighlight(player)
	end)
end

function PartyController:Start()
	Net.on("PartyUpdate", function(ids: unknown)
		if typeof(ids) ~= "table" then
			return
		end
		local list = {}
		for _, id in ids :: { unknown } do
			if typeof(id) == "number" then
				table.insert(list, id)
				invites[id] = nil -- уже вместе — приглашение не нужно
			end
		end
		members = list
		refreshHighlights()
		PartyController.Changed:Fire()
	end)
	Net.on("PartyInvite", function(userId: unknown, name: unknown)
		if typeof(userId) ~= "number" or typeof(name) ~= "string" then
			return
		end
		invites[userId] = { userId = userId, name = name, expiresAt = os.clock() + PartyConfig.InviteTtl }
		PartyController.Changed:Fire()
		-- Когда приглашение истечёт, интерфейс уберёт его сам.
		task.delay(PartyConfig.InviteTtl + 0.1, function()
			PartyController.Changed:Fire()
		end)
	end)

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		watchPlayer(player)
		PartyController.Changed:Fire()
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		invites[player.UserId] = nil
		PartyController.Changed:Fire()
	end)
end

return PartyController
