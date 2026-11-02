--!strict
--[[
	EffectsController — визуальные эффекты, которые рисует только клиент.
	Сейчас: трассеры выстрелов (событие ShotFired от сервера и свои выстрелы игрока).
	Урон считает сервер. Эффект лишь показывает, что выстрел был.
]]

local Debris = game:GetService("Debris")

local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))

local TRACER_LIFETIME = 0.06
local TRACER_COLOR = Color3.fromRGB(255, 210, 120)
local MAX_TRACER_LENGTH = 700

local EffectsController = {}

-- Нарисовать трассер от origin до impact (видно только этому игроку).
function EffectsController:drawTracer(origin: Vector3, impact: Vector3)
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

-- Вспышка взрыва: шар, который быстро исчезает.
function EffectsController:drawExplosion(center: Vector3, radius: number)
	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 140, 40)
	flash.Transparency = 0.35
	flash.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	flash.CFrame = CFrame.new(center)
	flash.Parent = workspace
	Debris:AddItem(flash, 0.25)
end

function EffectsController:Start()
	Net.on("ExplosionFx", function(center: unknown, radius: unknown)
		if typeof(center) == "Vector3" and typeof(radius) == "number" then
			EffectsController:drawExplosion(center, radius)
		end
	end)
	Net.on("ShotFired", function(origin: unknown, impact: unknown)
		if typeof(origin) == "Vector3" and typeof(impact) == "Vector3" then
			EffectsController:drawTracer(origin, impact)
		end
	end)
end

return EffectsController
