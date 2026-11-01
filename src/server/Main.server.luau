--!strict
--[[
	Точка входа сервера. Это единственный Script на сервере, вся логика — в модулях
	папки Services. Порядок запуска (Init → Start) описан в Shared/Loader.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)

Loader.run(script.Parent.Services, "Server")
