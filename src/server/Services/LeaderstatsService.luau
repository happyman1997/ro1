--!strict
--[[
	LeaderstatsService — показывает поля данных в стандартной таблице игроков (Tab).

	ВАЖНО: leaderstats — только витрина. Клиент может поменять эти значения
	у себя на экране, поэтому сервер НИКОГДА не читает их как источник правды.
	Источник правды — только DataService.
]]

local DataService = require(script.Parent.DataService)

-- Какие числовые поля данных показывать (в этом порядке).
local SHOWN_KEYS = { "Cash" }

local LeaderstatsService = {}

function LeaderstatsService:Start()
	DataService:onLoaded(function(player: Player, data)
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		for _, key in SHOWN_KEYS do
			local stat = Instance.new("IntValue")
			stat.Name = key
			stat.Value = (data :: any)[key]
			stat.Parent = folder
		end
		-- Родитель последним: таблица игроков сразу увидит все значения.
		folder.Parent = player
	end)

	DataService.Changed:Connect(function(player: Player, key: string, value: any)
		local folder = player:FindFirstChild("leaderstats")
		local stat = if folder then folder:FindFirstChild(key) else nil
		if stat and stat:IsA("IntValue") then
			stat.Value = value
		end
	end)
end

return LeaderstatsService
