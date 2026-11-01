--!strict
--[[
	EffectsController — визуальные эффекты, которые рисует только клиент.
	Сейчас: трассеры выстрелов охраны (событие DefenderFired).
	Урон считает сервер. Эффект лишь показывает, что выстрел был.
]]

local Debris = game:GetService("Debris")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

local TRACER_LIFETIME = 0.06
local TRACER_COLOR = Color3.fromRGB(255, 210, 120)
local MAX_TRACER_LENGTH = 500

local EffectsController = {}

local function drawTracer(origin: Vector3, impact: Vector3)
	local length = (impact - origin).Magnitude
	if length < 0.1 or length > MAX_TRACER_LENGTH then
		return
	end
	local tracer = Instance.new("Part")
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.CanTouch = false
	tracer.CastShadow = false
	tracer.Material = Enum.Material.Neon
	tracer.Color = TRACER_COLOR
	tracer.Size = Vector3.new(0.08, 0.08, length)
	tracer.CFrame = CFrame.lookAt(origin, impact) * CFrame.new(0, 0, -length / 2)
	tracer.Parent = workspace -- деталь создана клиентом и видна только ему
	Debris:AddItem(tracer, TRACER_LIFETIME)
end

function EffectsController:Start()
	Net.on("DefenderFired", function(origin: unknown, impact: unknown)
		if typeof(origin) == "Vector3" and typeof(impact) == "Vector3" then
			drawTracer(origin, impact)
		end
	end)
end

return EffectsController
