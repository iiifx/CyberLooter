# CyberLooter — technical research

Dated 2026-08-03. Everything below is verified against source unless explicitly marked
as an assumption.

## Sources

| Source | What it provides |
|---|---|
| [In-Question/MOD_Development_Reference](https://github.com/In-Question/MOD_Development_Reference) | Decompiled game scripts (1755 `.swift` files) plus Lua definitions for the CET API and game classes |
| [maximegmd/CyberEngineTweaks](https://github.com/maximegmd/CyberEngineTweaks) | CET source. Current release v1.37.1 (2025-09-28) |
| [rodikh/BetterLootMarkers](https://github.com/rodikh/BetterLootMarkers-Cyberpunk-mod) | A working CET loot mod, used purely as a reference for which APIs exist. No code is copied — the project carries no license |

---

## 1. How the game actually loots a corpse — VERIFIED

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

**Conclusion.** Pressing F on a corpse runs exactly one function:
`TransactionSystem.TransferAllItems(source, player)`. There is no hidden pipeline behind it.

The function is reachable from Lua, per
`Definitions/Game_Definitions/classes/gameTransactionSystem.lua:478`:

```lua
function gameTransactionSystem:TransferAllItems(source, target) return end
```

In CET that is `Game.GetTransactionSystem():TransferAllItems(target, player)`.

## 2. The "looted" state cleans itself up — VERIFIED

This removes the biggest risk identified during planning. State cleanup hangs off
inventory events, not off the interaction, so it happens no matter how the items leave.

`core/components/lootContainers.swift:195` (`gameLootBag`) and
`core/components/inventoryComponent.swift:380` (the shared inventory component):

```swift
protected cb func OnInventoryEmptyEvent(evt: ref<OnInventoryEmptyEvent>) -> Bool {
  GameObjectEffectHelper.StartEffectEvent(this, n"fx_empty");
  this.m_lootQuality = gamedataQuality.Invalid;
  this.m_isEmpty = true;
  GameObject.UntagObject(this);
  this.RegisterToHUDManagerByTask(false);   // drops out of the HUD
  ...
}
```

`cyberpunk/items/item.swift:58`:

```swift
protected cb func OnItemLooted(evt: ref<ItemLootedEvent>) -> Bool {
  let evtToSend: ref<UnregisterAllMappinsEvent> = new UnregisterAllMappinsEvent();
  this.QueueEvent(evtToSend);   // the map marker goes away
  ...
}
```

**Conclusion.** Take the items and the game clears the marker, drops the highlight, removes
the HUD entry and plays the "emptied" effect by itself. Nothing to replicate.

## 3. Quest loot can be filtered out — VERIFIED

`core/components/lootContainers.swift`:

```swift
public const func IsQuest() -> Bool {
  return this.m_hasQuestItems || this.m_markAsQuest;
}
```

Available on `gameLootBag`, `gameItemDropObject` and containers. At the item level there is
also `LootItemType.Quest` (`cyberpunk/UI/interactions/looting.swift:567`). One check either way.

## 4. "What the game lets you pick up" already exists as a condition — VERIFIED

`cyberpunk/interactions/scriptedConditions.swift:275` defines `LootPickupScriptedCondition`,
the exact test the game applies to ground items:

- heavy weapons cannot be picked up while the player is carrying something;
- grenades and healing items cannot be picked up when their charges are already full;
- otherwise, allowed.

Assumption (unverified): the condition can be instantiated from Lua and called via
`:Test(player, obj)`. If not, the logic is small enough to reproduce.

## 5. Detecting an active vanilla interaction — VERIFIED

`core/blackboard/blackboardDefinitions.swift:805` defines the `UIInteractionsDef` blackboard
with an `InteractionChoiceHub` field. Game-side usage, `cyberpunk/player/player.swift:905`:

```swift
let bboard = GameInstance.GetBlackboardSystem(this.GetGame()).Get(GetAllBlackboardDefs().UIInteractions);
let hub: InteractionChoiceHubData = FromVariant(bboard.GetVariant(GetAllBlackboardDefs().UIInteractions.InteractionChoiceHub));
ArrayClear(hub.choices);
```

**Conclusion.** A non-empty `hub.choices` means a live interaction prompt under the cursor.
That is the signal for "the key belongs to the game right now, stay out of it".

## 6. CET does not consume the key press — VERIFIED

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

CET listens to raw input and always returns 0, so the key still reaches the game.
Consequences:

- binding our action to the interact key is safe, vanilla behaviour is unaffected;
- but we cannot suppress the vanilla action either — hence the check in §5;
- CET binds do not fire while the CET overlay is open (`ExecuteSingleInput`).

## 7. Hold detection is supported out of the box — VERIFIED

`Definitions/CET_Definitons/cet.lua`:

```lua
---@alias CETInputHandler fun(isDown: boolean): void
function registerInput(id, description, callback) end
function IsBound(id) end
function GetBind(id) end
```

`registerInput` delivers both press and release, so hold duration is ours to measure.
`RecordKeyDown` in `VKBindings.cpp` filters auto-repeat, so the press event arrives once.
`IsBound`/`GetBind` let the UI report an unassigned key.

## 8. An overlay indicator can be drawn — VERIFIED

`src/d3d12/D3D12_Functions.cpp:358` calls `CET::Get().GetVM().Draw()` every frame inside
`PrepareUpdate()`, unconditionally. `LuaVM::Draw()` only filters on `m_initialized` and
`m_drawBlocked`; overlay state is irrelevant.

**Conclusion.** `registerForEvent("onDraw", ...)` always runs, so an ImGui indicator is
possible without native widgets. (Used only as the fallback path — see §10.)

## 9. Finding loot around the player — THE REMAINING UNKNOWN

Three candidates, none verified in-game:

**A. Targeting system.** `gametargetingTargetingSystem:GetTargetParts(instigator, query)`
with a `TargetSearchQuery` (`maxDistance`, `searchFilter`, `testedSet`). Game-side example
in `cyberpunk/devices/core/sensorDevice.swift:1919`:

```swift
searchQuery.searchFilter = TSF_And(TSF_Not(TSFMV.Att_Friendly), ...);
searchQuery.testedSet = TargetingSet.Complete;
GameInstance.GetTargetingSystem(...).GetTargetParts(player, searchQuery, targets);
target = TS_TargetPartInfo.GetComponent(targets[i]).GetEntity() as GameObject;
```

Upside: a true metric radius, and `TargetingSet.Complete` ignores where the player is
looking. Risk: the `TSFMV` filters are written around puppets and devices
(`Obj_Puppet`, `Obj_Device`, `Obj_Other`) — whether loot bags and ground items are covered
is unknown.

**B. Mappin system.** `gamemappinsMappinSystem:GetMappins(targetType)`.
Upside: returns precisely what the game itself treats as nearby loot.
Risk: signature and return shape are undocumented.

**C. Mappin controller hook.** The BetterLootMarkers approach: `ObserveAfter` on
`GameplayMappinController.UpdateVisibility`, then `mappin:GetEntityID()` →
`Game.FindEntityByID()`. Upside: proven in a shipping mod. Downside: passive — the game
calls us rather than us querying it — so it needs its own registry and pruning.

**Decision.** Implement all three as a fallback chain in order A → B → C and log the outcome
of each. The first real run on the player's machine settles it, and the losers get deleted.

## 10. Button prompts can be rendered by the engine — VERIFIED

This removes the need to draw the indicator at all. The game has a first-class hint system —
the one behind "Take", "Hold to drag body" and the rest.

Game code, `cyberpunk/player/psm/defaultTransition.swift:1709`:

```swift
protected final const func ShowInputHint(scriptInterface, actionName: CName, source: CName,
    label: script_ref<String>, opt holdIndicationType: inkInputHintHoldIndicationType,
    opt enableHoldAnimation: Bool, ...) -> Void {
  data.action = actionName;
  data.source = source;
  data.localizedLabel = Deref(label);
  data.holdIndicationType = holdIndicationType;
  data.enableHoldAnimation = enableHoldAnimation;
  evt = new UpdateInputHintEvent();
  evt.data = data;
  evt.show = true;
  evt.targetHintContainer = n"GameplayInputHelper";
  scriptInterface.GetUISystem().QueueEvent(evt);
}
```

The struct (`orphans.swift:27943`) and enum (`orphans.swift:6983`):

```swift
public native struct InputHintData {
  action, source, groupId: CName;
  localizedLabel: String;
  queuePriority, sortingPriority: Int32;
  holdIndicationType: inkInputHintHoldIndicationType;   // FromInputConfig | Press | Hold
  enableHoldAnimation: Bool;
  ...
}
```

CET exposes a **ready-made global helper** — `Definitions/Game_Definitions/globals.lua:3679`:

```lua
---@param show Bool
---@param data gameuiInputHintData
---@param targetHintContainer CName|string
function Game.SendInputHintData(show, data, targetHintContainer) return end
```

The struct is constructible from Lua via `gameuiInputHintData.new()`
(`Definitions/Game_Definitions/classes/gameuiInputHintData.lua`).

**Conclusion.** The indicator is an engine call rather than custom drawing:

```lua
local hint = gameuiInputHintData.new()
hint.action = CName.new("Choice1")     -- engine substitutes the player's own key
hint.source = CName.new("CyberLooter")
hint.localizedLabel = "Loot All · 7"
hint.holdIndicationType = inkInputHintHoldIndicationType.Hold
hint.enableHoldAnimation = true
Game.SendInputHintData(true, hint, "GameplayInputHelper")
```

This gets native styling, native placement, the native hold animation and the correct key
glyph for both keyboard and gamepad.

Open questions (assumptions, to be settled by the log on the first deployment):
- whether re-sending with the same `action` + `source` updates the existing hint or stacks
  a duplicate (plan B: take it down with `show=false` and re-send);
- whether the native hold animation timing matches our threshold — it comes from the
  action's input config, not from us.

## 11. Registration must happen at load time — VERIFIED

`src/scripting/ScriptContext.cpp:195`:

```cpp
const auto result = sb.ExecuteFile(UTF16ToUTF8(path.native()));
...
env["registerForEvent"] = sol::nil;
env["registerHotkey"] = sol::nil;
env["registerInput"] = sol::nil;
```

CET nils out the registration functions the moment `init.lua` finishes executing. Calling
`registerInput` from inside `onInit` therefore fails outright — the binding would never
appear in the Bindings tab. All registration has to happen while `init.lua` runs.

Related: `src/scripting/LuaSandbox.cpp` wraps `io.open` and resolves relative paths through
`GetLuaPath` against the mod's own directory, so `config.json` and the log file resolve
correctly regardless of when they are opened.

---

## Risk summary

| Risk | Assessment | Mitigation |
|---|---|---|
| Loot around the player is not found | Medium | Three strategies with fallback, plus logging |
| `TransferAllItems` fails on containers or ground items | Low | Confirmed by game code for corpses; elsewhere, verified by emptiness check with per-item fallback |
| Conflict with the vanilla interact key | Low | `InteractionChoiceHub` check before acting |
| Frame drops at large radius | Low | Throttled scanning, per-sweep object cap |
| Broken quest | Low | `IsQuest()` filter, on by default |
| Inventory filling with junk | Certain | A deliberate user choice; filters left for later |
