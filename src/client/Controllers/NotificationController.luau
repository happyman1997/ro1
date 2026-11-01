--!strict
--[[
	NotificationController — всплывающие уведомления от сервера (событие Notify).
	Пока используется встроенный тост Roblox (SetCore). Свой интерфейс
	подключается заменой функции show.
]]

local StarterGui = game:GetService("StarterGui")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

local TITLE = "Ресторан"
local DURATION = 5

local NotificationController = {}

local function show(text: string)
	-- В первые секунды после входа SetCore может быть ещё не готов — повторяем.
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCore("SendNotification", { Title = TITLE, Text = text, Duration = DURATION })
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
end

function NotificationController:notify(text: string)
	task.spawn(show, text)
end

function NotificationController:Start()
	Net.on("Notify", function(text: unknown)
		if typeof(text) == "string" then
			task.spawn(show, text)
		end
	end)
end

return NotificationController
