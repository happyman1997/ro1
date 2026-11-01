--!strict
--[[
	CoinService — образец механики на CollectionService.

	Любая деталь (BasePart) с тегом "Coin" становится монетой: игрок касается её,
	получает монеты, монета исчезает и через RESPAWN_TIME появляется снова.
	Скрипт внутрь монет класть не нужно: один сервис обслуживает все монеты,
	включая созданные во время игры.

	Как сделать монету в Studio: создайте Part (Anchored = true, CanTouch = true),
	в окне Properties, в разделе Tags, добавьте тег Coin. Необязательный
	атрибут Value (целое число ≥ 1) задаёт номинал, иначе DEFAULT_VALUE.

	Защита:
	• Касание обрабатывается только на сервере, награду выдаёт сервер.
	• Эксплойт может «касаться» деталей издалека (firetouchinterest), поэтому
	  сервер сам проверяет расстояние от персонажа до монеты.
	• Персонажем управляет клиент (сетевое владение), поэтому читер может
	  телепортироваться к монетам. Это закрывается отдельной серверной проверкой
	  скорости перемещения — добавим, когда определимся с жанром и картой.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local DataService = require(script.Parent.DataService)

local COIN_TAG = "Coin"
local DEFAULT_VALUE = 1
local RESPAWN_TIME = 10 -- секунд до повторного появления
local PICKUP_MARGIN = 8 -- запас в студах сверх размера монеты (руки, ноги, лаг)

type CoinState = {
	connection: RBXScriptConnection,
	collected: boolean,
	transparency: number, -- исходная прозрачность, чтобы вернуть её при появлении
}

local coins: { [BasePart]: CoinState } = {}

local CoinService = {}

local function getCoinValue(coin: BasePart): number
	local value = coin:GetAttribute("Value")
	if typeof(value) == "number" and value >= 1 and value < math.huge then
		return math.floor(value)
	end
	return DEFAULT_VALUE
end

local function setVisible(coin: BasePart, state: CoinState, visible: boolean)
	coin.Transparency = if visible then state.transparency else 1
	coin.CanTouch = visible
end

local function onTouched(coin: BasePart, hit: BasePart)
	local state = coins[coin]
	if state == nil or state.collected then
		return
	end

	-- hit может быть частью тела, аксессуаром или инструментом — ищем модель персонажа.
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = if character then Players:GetPlayerFromCharacter(character) else nil
	if character == nil or player == nil or not DataService:isLoaded(player) then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = if humanoid then humanoid.RootPart else nil
	if humanoid == nil or humanoid.Health <= 0 or root == nil then
		return
	end

	-- Анти-чит: засчитываем касание, только если персонаж действительно рядом.
	local maxDistance = coin.Size.Magnitude / 2 + PICKUP_MARGIN
	if (root.Position - coin.Position).Magnitude > maxDistance then
		return
	end

	state.collected = true
	setVisible(coin, state, false)
	DataService:increment(player, "Coins", getCoinValue(coin))

	task.delay(RESPAWN_TIME, function()
		-- Монету могли удалить или снять с неё тег, пока она «перезаряжалась».
		if coins[coin] == state then
			state.collected = false
			setVisible(coin, state, true)
		end
	end)
end

local function onCoinAdded(instance: Instance)
	if not instance:IsA("BasePart") then
		warn(`[CoinService] Тег {COIN_TAG} должен быть на детали (BasePart): {instance:GetFullName()}`)
		return
	end
	local coin = instance :: BasePart
	if coins[coin] then
		return
	end

	coins[coin] = {
		connection = coin.Touched:Connect(function(hit: BasePart)
			onTouched(coin, hit)
		end),
		collected = false,
		transparency = coin.Transparency,
	}
end

local function onCoinRemoved(instance: Instance)
	local coin = instance :: BasePart
	local state = coins[coin]
	if state == nil then
		return
	end
	coins[coin] = nil
	state.connection:Disconnect()
	if state.collected then
		setVisible(coin, state, true) -- тег сняли во время перезарядки — возвращаем вид
	end
end

function CoinService:Start()
	-- Сначала подписка, потом обход: монета, добавленная между ними, не потеряется
	-- (повторное добавление onCoinAdded игнорирует).
	CollectionService:GetInstanceAddedSignal(COIN_TAG):Connect(onCoinAdded)
	CollectionService:GetInstanceRemovedSignal(COIN_TAG):Connect(onCoinRemoved)
	for _, instance in CollectionService:GetTagged(COIN_TAG) do
		onCoinAdded(instance)
	end
end

return CoinService
