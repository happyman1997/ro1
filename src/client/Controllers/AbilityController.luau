--!strict
--[[
	AbilityController — способность класса на клиенте.

	Клавиша Q (или кнопка в интерфейсе) просит сервер применить способность,
	передавая точку под курсором (для пробивного заряда). Что сработало и где,
	решает сервер. Метка разведчика подсвечивает присланную сервером охрану.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

local localPlayer = Players.LocalPlayer

local AbilityController = {}

function AbilityController:use()
	Net.fire("UseAbility", localPlayer:GetMouse().Hit.Position)
end

local function highlight(model: Instance, duration: number)
	local effect = Instance.new("Highlight")
	effect.FillColor = Color3.fromRGB(255, 70, 60)
	effect.OutlineColor = Color3.fromRGB(255, 255, 255)
	effect.FillTransparency = 0.4
	effect.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- видно сквозь стены
	effect.Parent = model
	Debris:AddItem(effect, duration)
end

function AbilityController:Start()
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.Q then
			AbilityController:use()
		end
	end)
	Net.on("MarkDefenders", function(list: unknown, duration: unknown)
		if type(list) ~= "table" or typeof(duration) ~= "number" then
			return
		end
		for _, model in list :: { any } do
			if typeof(model) == "Instance" and model:IsA("Model") then
				highlight(model, duration)
			end
		end
	end)
end

return AbilityController
