# ro1

Сессионный экшен-тайкун на Roblox: ресторан-крепость, автоматический доход,
штурм и ограбление чужих ресторанов на одной открытой карте. Код на Luau
хранится в git и синхронизируется со Studio через [Rojo](https://rojo.space).

Архитектура систем, схема данных, правила охраны и устройство моделей
уровней описаны в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Быстрый старт

1. Установите [Rokit](https://github.com/rojo-rbx/rokit) и в папке проекта выполните:

   ```bash
   rokit install
   ```

2. Установите плагин Rojo в Studio:

   ```bash
   rojo plugin install
   ```

3. Откройте в Studio любое место (например, Baseplate) и запустите сервер Rojo:

   ```bash
   rojo serve
   ```

   В Studio: вкладка **Plugins → Rojo → Connect**. Код из `src/` появится
   в нужных сервисах и будет обновляться при каждом сохранении файла.

4. Нажмите Play: тестовая карта уже в проекте. Список чат-команд для проверки —
   `/help` (подробности в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#10-тестовая-сцена)).

Без установки инструментов: на GitHub откройте **Actions → последний запуск →
Artifacts → `ro1-place`**, скачайте архив, распакуйте и откройте `ro1.rbxlx` в Studio.

Без Rojo можно собрать готовый файл места и открыть его в Studio:

```bash
rojo build -o build/ro1.rbxlx
```

### Сохранения в Studio

Пока место не опубликовано или выключен доступ к API, DataService хранит данные
в памяти (они пропадут после остановки) и пишет об этом в Output. Для проверки
настоящих сохранений: **File → Publish to Roblox**, затем **Game Settings →
Security → Enable Studio Access to API Services**.

## Структура

```
src/shared  → ReplicatedStorage.Shared          (видно серверу и клиенту)
  Loader         — запуск модулей: Init() у всех, затем Start() у всех
  Remotes        — реестр всех сетевых событий
  Guard          — проверка аргументов от клиента
  Signal         — события между модулями одной стороны
  DataTemplate   — шаблон и типы данных игрока
  CharacterUtil  — живой ли персонаж, оружие в руках
  Config/
    Tiers        — уровни ресторана: доход, касса, ремонт, время взлома
    Defense      — типы охраны: обзор, урон, правило обнаружения
    Classes      — RPG-классы: здоровье, скорость, маскировка, приоритет у охраны

src/server  → ServerScriptService.Server        (клиенту не видно)
  Main.server    — единственный Script, запускает Services
  Services/
    NetService          — создание Remotes, лимиты частоты, проверки, анти-чит
    DataService         — загрузка/сохранение с блокировкой сессии
    PlotService         — участки, владельцы, замена моделей уровней, улучшение
    ClassService        — класс игрока, маскировка разведчика
    CashRegisterService — касса: выручка, сбор владельцем, взлом
    RestaurantService   — доход, остановка при разрушении, ремонт
    GuardAIService      — ИИ охраны и турелей
    LeaderstatsService  — таблица игроков (только витрина)
    SettingsService     — образец запроса клиент → сервер
    DevCommandsService  — чат-команды для тестов (только в Studio)
  Modules/
    RateLimiter    — «ведро токенов»
    Migrations     — миграции формата данных
    LineOfSight    — видимость и линия огня с учётом стекла и тонких стен
    NpcUtil        — сетевое владение NPC за сервером

src/client  → StarterPlayerScripts.Client
  Main.client    — единственный LocalScript, запускает Controllers
  Controllers/
    StateController        — копия данных игрока для интерфейса
    SettingsController     — изменение настроек
    NotificationController — уведомления от сервера
    RegisterController     — показ нужной подсказки у кассы
    EffectsController      — трассеры выстрелов охраны
  Modules/
    Net            — fire() на сервер, on() от сервера

scene/      → тестовая карта: участки (Workspace.Plots) и модели уровней
              (ServerStorage.Restaurants) в формате .model.json
tools/      → check_scene.py — проверка сцены в CI
tests/      → симулятор сервера (sim/) и сценарии (specs/), запуск — run.luau
```

Тестовая карта хранится в git (`scene/`), поэтому её видно в истории и её проверяет
CI. Настоящие модели из Studio сохраняются в `.rbxmx` и подключаются так же.
Rojo управляет только папками, перечисленными в `default.project.json`.

## Правила проекта

### Модули
- Новый сервис — ModuleScript в `src/server/Services`, новый контроллер —
  в `src/client/Controllers`. Загрузчик подхватит их сам.
- В `Init()` готовим только своё состояние. В `Start()` подключаем события
  и обращаемся к другим модулям.
- Объекты с одинаковым поведением (касса, персонал, охрана, мебель) помечаем
  **тегом CollectionService**. Скрипты внутрь деталей не кладём.
- Все файлы начинаются с `--!strict`, комментарии пишем на русском.

### Сеть
1. Объявите событие в `src/shared/Remotes.luau` (`direction` и `kind`).
2. На сервере подпишитесь в `Start()`:
   ```lua
   NetService:on("BuyItem", {
       args = { Guard.keyOf(ShopItems), Guard.integer(1, 99) },
       rate = 2, burst = 5,
   }, function(player, itemId, amount) ... end)
   ```
3. На клиенте: `Net.fire("BuyItem", "Sword", 1)`.

### Данные
- Новое поле: добавьте его в `DataTemplate` (в тип и в `Template`). Старые
  сохранения получат значение по умолчанию сами.
- Меняете формат существующего поля: увеличьте `DataTemplate.Version`
  и добавьте функцию в `Migrations`.
- Меняйте данные только через `DataService:set / increment / update`.

## Безопасность: чек-лист для каждой механики

- [ ] Клиент присылает **намерение** («хочу купить X»), а не результат
      («у меня теперь 1000 монет»). Результат считает сервер.
- [ ] Все аргументы Remote проверены через `Guard`: тип, диапазон, NaN,
      длина строки, существование id.
- [ ] Смысл запроса проверен на сервере: хватает ли денег, есть ли предмет,
      рядом ли объект (расстояние), не на кулдауне ли действие.
- [ ] Кулдауны и таймеры живут на сервере. Клиентский таймер нужен только для отображения.
- [ ] У события разумный `rate`/`burst`.
- [ ] Валюта, урон, награды и инвентарь меняются только на сервере.
- [ ] Ничего не читаем из leaderstats и атрибутов, которые клиент мог менять
      у себя: источник правды — DataService.
- [ ] Текст от игроков, который увидят другие, проходит через `TextService` (фильтр).
- [ ] Секретные данные и шаблоны лежат в `ServerStorage`/`ServerScriptService`,
      а не в `ReplicatedStorage`.
- [ ] Никакого `RemoteFunction:InvokeClient` и `loadstring`.

Помните: персонажем управляет клиент (сетевое владение), поэтому позицию
игрока можно подделать телепортом. Для механик, где важна позиция, нужна
серверная проверка скорости перемещения.

## Инструменты

```bash
selene src
```

```bash
stylua src
```

```bash
rojo sourcemap -o sourcemap.json
```

`selene` — линтер, `stylua` — форматирование. Sourcemap нужен расширению
luau-lsp в VS Code, чтобы понимать пути вида `script.Parent.Services`.
Рекомендуемые расширения перечислены в `.vscode/extensions.json`.

### Автотесты

`tests/` — симулятор сервера Roblox на [Lune](https://lune-org.github.io/docs).
Он запускает настоящий серверный код из собранного места: игроки, персонажи,
лучи видимости, события, виртуальное время. Сценарии в `tests/specs`: доход
и касса, улучшение и ремонт, охрана и турели, бронестекло, взлом и поимка вора,
проверки Remote и анти-флуд.

```bash
rojo build default.project.json -o build/ro1.rbxlx
```

```bash
lune run tests/run.luau build/ro1.rbxlx
```

Чтобы запустить часть тестов, добавьте фильтр по названию:
`lune run tests/run.luau build/ro1.rbxlx охрана`. Флаг `--verbose` показывает
предупреждения сервера.

Физики, клиента и рендера в симуляторе нет. Это проверка логики сервера, а не
замена плейтеста.

### CI

Все проверки — `rojo build`, проверка сцены, автотесты, `luau-lsp analyze`
(строгие типы), StyLua и selene — автоматически запускаются в GitHub Actions
на каждый пуш и пулл-реквест: вкладка **Actions → «Проверка кода»**. Версии
инструментов берутся из `rokit.toml`.
