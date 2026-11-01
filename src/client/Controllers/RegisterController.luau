--!strict
--[[
	RegisterController — подсказки кассы на клиенте.

	Сервер ставит на каждую кассу две подсказки: «Забрать выручку» (Role = Collect)
	и «Взломать» (Role = Hack). Клиент показывает только подходящую:
	своя касса — Collect, чужая касса и класс с взломом — Hack.
	Это ТОЛЬКО удобство: сервер всё равно проверяет роль, расстояние и таймер.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local PROMPT_TAG = "RegisterPrompt"

local localPlayer = Players.LocalPlayer

local RegisterController = {}

-- Касса на участке локального игрока? Владельца хранит атрибут OwnerUserId модели участка.
local function isMine(prompt: Instance): boolean
	local node: Instance? = prompt.Parent
	while node do
		local ownerId = node:GetAttribute("OwnerUserId")
		if ownerId ~= nil then
			return ownerId == localPlayer.UserId
		end
		node = node.Parent
	end
	return false
end

local function refresh(instance: Instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end
	local prompt = instance :: ProximityPrompt
	local role = prompt:GetAttribute("Role")
	if role == "Collect" then
		prompt.Enabled = isMine(prompt)
	elseif role == "Hack" then
		prompt.Enabled = localPlayer:GetAttribute("CanHack") == true and not isMine(prompt)
	end
end

local function refreshAll()
	for _, prompt in CollectionService:GetTagged(PROMPT_TAG) do
		refresh(prompt)
	end
end

function RegisterController:Start()
	CollectionService:GetInstanceAddedSignal(PROMPT_TAG):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("CanHack"):Connect(refreshAll)
	refreshAll()

	Net.on("HackState", function(state: string, value: any)
		if state == "Started" and typeof(value) == "number" then
			local seconds = math.max(0, math.ceil(value - workspace:GetServerTimeNow()))
			NotificationController:notify(
				`Взлом: {seconds} с. Не отходите от кассы и не доставайте оружие.`
			)
		end
	end)
end

return RegisterController
