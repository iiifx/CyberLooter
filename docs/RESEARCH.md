# CyberLooter — технический ресёрч

Дата: 2026-08-03. Всё ниже проверено по исходникам, если явно не помечено как гипотеза.

## Источники

| Источник | Что даёт |
|---|---|
| [In-Question/MOD_Development_Reference](https://github.com/In-Question/MOD_Development_Reference) | Декомпилированные скрипты игры (1755 файлов `.swift`) + Lua-определения CET API и игровых классов |
| [maximegmd/CyberEngineTweaks](https://github.com/maximegmd/CyberEngineTweaks) | Исходники CET. Актуальный релиз — v1.37.1 (28.09.2025) |
| [rodikh/BetterLootMarkers](https://github.com/rodikh/BetterLootMarkers-Cyberpunk-mod) | Рабочий пример CET-мода про лут. Только как образец, код не заимствуем (лицензии нет) |

---

## 1. Как игра на самом деле лутает труп — ПРОВЕРЕНО

`DecompiledGameScripts/cyberpunk/puppet/scriptedPuppet.swift:2880`

```swift
protected cb func OnInteraction(choiceEvent: ref<InteractionChoiceEvent>) -> Bool {
  let choice: String = choiceEvent.choice.choiceMetaData.tweakDBName;
  if Equals(choice, "Loot") {
    this.LootAllItems(choiceEvent);
  } ...
  RPGManager.ProcessReadAction(choiceEvent);
  this.OrderChoice(choiceEvent);
}

private final func LootAllItems(choiceEvent: ref<InteractionChoiceEvent>) -> Void {
  GameInstance.GetTransactionSystem(this.GetGame()).TransferAllItems(this, choiceEvent.activator);
}
```

**Вывод.** Когда игрок жмёт F на трупе, игра вызывает ровно одну функцию:
`TransactionSystem.TransferAllItems(источник, игрок)`. Это и есть «штатный механизм подбора»,
никакого скрытого пайплайна нет.

Функция доступна из Lua — подтверждено определением
`Definitions/Game_Definitions/classes/gameTransactionSystem.lua:478`:

```lua
function gameTransactionSystem:TransferAllItems(source, target) return end
```

То есть в CET это `Game.GetTransactionSystem():TransferAllItems(target, player)`.

## 2. Состояние «обыскано» выставляется само — ПРОВЕРЕНО

Это снимает главный риск, которого я опасался на этапе обсуждения. Уборка состояния
привязана не к интеракции, а к событиям инвентаря — то есть срабатывает при **любом**
способе изъятия предметов.

`core/components/lootContainers.swift:195` (`gameLootBag`) и
`core/components/inventoryComponent.swift:380` (общий инвентарь-компонент):

```swift
protected cb func OnInventoryEmptyEvent(evt: ref<OnInventoryEmptyEvent>) -> Bool {
  GameObjectEffectHelper.StartEffectEvent(this, n"fx_empty");
  this.m_lootQuality = gamedataQuality.Invalid;
  this.m_isEmpty = true;
  GameObject.UntagObject(this);
  this.RegisterToHUDManagerByTask(false);   // снятие с HUD
  ...
}
```

`cyberpunk/items/item.swift:58`:

```swift
protected cb func OnItemLooted(evt: ref<ItemLootedEvent>) -> Bool {
  let evtToSend: ref<UnregisterAllMappinsEvent> = new UnregisterAllMappinsEvent();
  this.QueueEvent(evtToSend);   // маркер на карте гаснет
  ...
}
```

**Вывод.** Забрали предметы → игра сама гасит маркер, снимает подсветку, убирает объект
из HUD и проигрывает эффект опустошения. Руками ничего доделывать не нужно.

## 3. Квестовый лут можно отфильтровать — ПРОВЕРЕНО

`core/components/lootContainers.swift`:

```swift
public const func IsQuest() -> Bool {
  return this.m_hasQuestItems || this.m_markAsQuest;
}
```

Метод есть у `gameLootBag`, `gameItemDropObject` и контейнеров. Дополнительно на уровне
отдельного предмета есть `LootItemType.Quest` (`cyberpunk/UI/interactions/looting.swift:567`).
Фильтр обойдётся в одну проверку.

## 4. «Правила игры: что можно поднять» — ПРОВЕРЕНО, есть готовое условие

`cyberpunk/interactions/scriptedConditions.swift:275` — класс `LootPickupScriptedCondition`,
это ровно тот тест, который игра применяет к предметам на земле:

- тяжёлое оружие нельзя поднять, если игрок уже что-то несёт;
- гранаты и лечилки нельзя поднять, если заряды и так на максимуме;
- в остальных случаях — можно.

Гипотеза (не проверено): условие можно инстанцировать из Lua и вызвать `:Test(player, obj)`.
Если не выйдет — логика простая, повторим её сами.

## 5. Определение «есть ли сейчас ванильное действие на F» — ПРОВЕРЕНО

`core/blackboard/blackboardDefinitions.swift:805` — блэкборд `UIInteractionsDef`, поле
`InteractionChoiceHub`. Пример чтения из игрового кода, `cyberpunk/player/player.swift:905`:

```swift
let bboard = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UIInteractions);
let hub: InteractionChoiceHubData = FromVariant(bboard.GetVariant(GetAllBlackboardDefs().UIInteractions.InteractionChoiceHub));
ArrayClear(hub.choices);
```

**Вывод.** Непустой `hub.choices` = под курсором есть активное взаимодействие. Это и есть
наш признак «сейчас F занята игрой, не вмешиваемся».

## 6. CET не отбирает нажатие у игры — ПРОВЕРЕНО

`src/VKBindings.cpp:537`:

```cpp
LRESULT VKBindings::OnWndProc(HWND, UINT auMsg, WPARAM, LPARAM alParam) {
    switch (auMsg) {
    case WM_INPUT: return HandleRAWInput(reinterpret_cast<HRAWINPUT>(alParam));
    ...
    }
    return 0;
}
```

CET слушает raw input и всегда возвращает 0 — нажатие уходит в игру как обычно.
Следствия:
- повесить наш хоткей на F безопасно, ванильное поведение F не сломается;
- но и подавить ванильное действие мы не можем — отсюда необходимость проверки из п. 5;
- бинды CET не срабатывают, пока открыт оверлей CET (там же в `ExecuteSingleInput`).

## 7. Удержание клавиши поддерживается из коробки — ПРОВЕРЕНО

`Definitions/CET_Definitons/cet.lua`:

```lua
---@alias CETInputHandler fun(isDown: boolean): void
function registerInput(id, description, callback) end
function IsBound(id) end
function GetBind(id) end
```

`registerInput` отдаёт и нажатие, и отпускание → таймер удержания меряем сами.
`RecordKeyDown` в `VKBindings.cpp` отсекает автоповтор, так что событие «нажал» приходит один раз.
`IsBound`/`GetBind` позволят подсказать в интерфейсе, что клавиша ещё не назначена.

## 8. Индикатор поверх игры рисовать можно — ПРОВЕРЕНО

`src/d3d12/D3D12_Functions.cpp:358` — `CET::Get().GetVM().Draw()` вызывается в каждом кадре
внутри `PrepareUpdate()`, безусловно. `LuaVM::Draw()` фильтрует только по `m_initialized` и
`m_drawBlocked`. Состояние оверлея на это не влияет.

**Вывод.** `registerForEvent("onDraw", ...)` работает всегда, значит ImGui-индикатор удержания
можно показывать прямо в игре без всяких нативных виджетов.

## 9. Поиск лута вокруг игрока — ГЛАВНАЯ ОСТАВШАЯСЯ НЕИЗВЕСТНОСТЬ

Три кандидата, ни один не проверен в бою:

**A. Система таргетинга.** `gametargetingTargetingSystem:GetTargetParts(instigator, query)`,
структура запроса `TargetSearchQuery` (`maxDistance`, `searchFilter`, `testedSet`).
Рабочий пример из игры — `cyberpunk/devices/core/sensorDevice.swift:1919`:

```swift
searchQuery.searchFilter = TSF_And(TSF_Not(TSFMV.Att_Friendly), ...);
searchQuery.testedSet = TargetingSet.Complete;
GameInstance.GetTargetingSystem(...).GetTargetParts(player, searchQuery, targets);
target = TS_TargetPartInfo.GetComponent(targets[i]).GetEntity() as GameObject;
```

Плюс: честный радиус в метрах, `TargetingSet.Complete` игнорирует направление взгляда.
Риск: фильтры `TSFMV` заточены под персонажей и устройства (`Obj_Puppet`, `Obj_Device`,
`Obj_Other`). Попадают ли туда мешки с лутом и предметы на земле — неизвестно.

**B. Система маркеров.** `gamemappinsMappinSystem:GetMappins(targetType)`.
Плюс: даёт ровно то, что игра сама считает лутом поблизости.
Риск: сигнатура и формат ответа не документированы.

**C. Перехват контроллеров маркеров.** Подход BetterLootMarkers: `ObserveAfter` на
`GameplayMappinController.UpdateVisibility`, затем `mappin:GetEntityID()` →
`Game.FindEntityByID()`. Плюс: работает в живом моде прямо сейчас. Минус: пассивный сбор
(мы не запрашиваем список, а ждём, когда игра позовёт нас), нужен свой реестр с чисткой.

**Решение.** Реализуем все три как цепочку стратегий с откатом, порядок A → B → C,
результат каждой пишем в диагностический лог. Первый же запуск на твоей машине покажет,
какая работает, — и лишние выкинем.

---

## Сводка рисков

| Риск | Оценка | Что делаем |
|---|---|---|
| Не найдём лут вокруг | Средний | Три стратегии с откатом + лог |
| `TransferAllItems` не сработает на контейнерах/дропе | Низкий | Для трупов подтверждено кодом игры; на остальном — лог и откат на поштучный `TransferItem` |
| Конфликт с ванильной F | Низкий | Проверка `InteractionChoiceHub` перед срабатыванием |
| Просадка FPS при большом радиусе | Низкий | Троттлинг сканирования, лимит объектов за проход |
| Сломанный квест | Низкий | Фильтр `IsQuest()`, включён по умолчанию |
| Перегруз инвентаря хламом | Гарантированный | Осознанный выбор пользователя; фильтры оставляем на будущее |
