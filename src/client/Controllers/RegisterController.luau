--!strict
--[[
	RegisterController — подсказки кассы на клиенте.

	Сервер ставит на каждую кассу две подсказки: «Забрать выручку» (Role = Collect)
	и «Взломать» (Role = Hack). Клиент показывает только подходящую:
	своя касса — Collect, чужая касса и класс с взломом — Hack (но не касса союзника).
	Это ТОЛЬКО удобство: сервер всё равно проверяет роль, расстояние и таймер.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local PartyController = require(script.Parent:WaitForChild("PartyController"))

local PROMPT_TAG = "RegisterPrompt"

local localPlayer = Players.LocalPlayer

local RegisterController = {}

-- Владелец участка, на котором стоит касса (атрибут OwnerUserId модели участка).
local function ownerOf(prompt: Instance): number?
	local node: Instance? = prompt.Parent
	while node do
		local ownerId = node:GetAttribute("OwnerUserId")
		if typeof(ownerId) == "number" then
			return ownerId
		end
		node = node.Parent
	end
	return nil
end

local function refresh(instance: Instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end
	local prompt = instance :: ProximityPrompt
	local role = prompt:GetAttribute("Role")
	local ownerId = ownerOf(prompt)
	local mine = ownerId == localPlayer.UserId
	if role == "Collect" then
		prompt.Enabled = mine
	elseif role == "Hack" then
		local ally = ownerId ~= nil and PartyController:isAlly(ownerId)
		prompt.Enabled = localPlayer:GetAttribute("CanHack") == true and not mine and not ally
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
	PartyController.Changed:Connect(refreshAll) -- вступил в группу или вышел
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
