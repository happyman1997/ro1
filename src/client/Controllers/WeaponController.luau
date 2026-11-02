--!strict
--[[
	WeaponController — стрельба на клиенте.

	Клик по оружию в руках → серверу уходит направление прицела (Net.fire("Fire")),
	а игрок сразу видит свой трассер. Попал или нет, решает только сервер.
	Оружие с оптикой (Scoped): правая кнопка мыши — приближение.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Weapons = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Weapons"))
local Net = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("Net"))
local EffectsController = require(script.Parent:WaitForChild("EffectsController"))

local DEFAULT_FOV = 70
local SCOPE_FOV = 20

local localPlayer = Players.LocalPlayer

local WeaponController = {}

local function camera(): Camera
	return workspace.CurrentCamera
end

local function onToolEquipped(tool: Tool)
	local weaponId = tool:GetAttribute("WeaponId")
	local info = if typeof(weaponId) == "string" then Weapons[weaponId] else nil
	if info == nil then
		return
	end

	local connections: { RBXScriptConnection } = {}
	local function cleanup()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		camera().FieldOfView = DEFAULT_FOV
	end

	table.insert(
		connections,
		tool.Activated:Connect(function()
			local character = localPlayer.Character
			local head = if character then character:FindFirstChild("Head") else nil
			if head == nil or not head:IsA("BasePart") then
				return
			end
			local origin = (head :: BasePart).Position
			local target = localPlayer:GetMouse().Hit.Position
			local direction = target - origin
			if direction.Magnitude < 0.01 then
				direction = camera().CFrame.LookVector
			end
			Net.fire("Fire", direction.Unit)
			EffectsController:drawTracer(origin, origin + direction.Unit * math.min(direction.Magnitude, info.Range))
		end)
	)

	if info.Scoped then
		table.insert(
			connections,
			UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
				if not processed and input.UserInputType == Enum.UserInputType.MouseButton2 then
					camera().FieldOfView = SCOPE_FOV
				end
			end)
		)
		table.insert(
			connections,
			UserInputService.InputEnded:Connect(function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton2 then
					camera().FieldOfView = DEFAULT_FOV
				end
			end)
		)
	end

	table.insert(connections, tool.Unequipped:Connect(cleanup))
	table.insert(
		connections,
		tool.AncestryChanged:Connect(function()
			if tool.Parent ~= localPlayer.Character then
				cleanup()
			end
		end)
	)
end

local function onCharacterAdded(character: Model)
	character.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Tool") then
			onToolEquipped(child :: Tool)
		end
	end)
end

function WeaponController:Start()
	localPlayer.CharacterAdded:Connect(onCharacterAdded)
	local character = localPlayer.Character
	if character then
		onCharacterAdded(character)
	end
end

return WeaponController
