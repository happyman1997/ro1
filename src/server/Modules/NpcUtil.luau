--!strict
--[[
	NpcUtil — общие операции с NPC (персонал, охрана, турели).

	ЗАЩИТА: незаякоренные детали рядом с игроком Roblox по умолчанию отдаёт под
	физический контроль его клиенту (сетевое владение). Эксплойт может тогда
	двигать NPC как угодно: утащить охранника за карту, скинуть повара в пустоту
	и тем самым «сломать» ресторан без боя. Поэтому все NPC принадлежат серверу.
]]

local NpcUtil = {}

-- Закрепить физику модели за сервером.
function NpcUtil.claimNetworkOwnership(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			-- Детали, приваренные к заякоренным, владельца не имеют — их пропускаем.
			if descendant:CanSetNetworkOwnership() then
				descendant:SetNetworkOwner(nil)
			end
		end
	end
end

return table.freeze(NpcUtil)
