--!strict
--[[
	Точка входа клиента. Это единственный LocalScript, вся логика — в модулях
	папки Controllers. Порядок запуска (Init → Start) описан в Shared/Loader.

	Скрипт лежит в StarterPlayerScripts, поэтому выполняется один раз за сессию
	и НЕ перезапускается при возрождении персонажа.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

Loader.run(script.Parent:WaitForChild("Controllers"), "Client")
