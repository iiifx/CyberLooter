# CyberLooter — technical research

Dated 2026-08-03. Everything below is verified against source unless explicitly marked
as an assumption.

## Sources

| Source | What it provides |
|---|---|
| [In-Question/MOD_Development_Reference](https://github.com/In-Question/MOD_Development_Reference) | Decompiled game scripts (1755 `.swift` files) plus Lua definitions for the CET API and game classes. Caveat: the RTTI definitions were dumped from game 2.01 / CET 1.27.1 and the decompiled scripts are older still, so signatures can lag behind 2.3 — §9 documents one case where they already do |
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

In CET that is `Game.GetTransactionSystem():TransferAllItems(source, player)` —
the first argument is the object being emptied, the second is the receiver.

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

## 9. Finding loot around the player — SETTLED IN-GAME (2026-08-03)

Three candidates were implemented as a fallback chain. The first in-game run resolved to
**strategy A (targeting system)**, with every sweep succeeding through it, so B was deleted
as proven dead and A was locked in for the session.

**That lock turned out to be the wrong design.** Play-testing found that loot stopped being
detected right after a fight: the player could stand in a pile of fresh corpses and the mod
saw nothing, while a save and reload made the same bodies work immediately. The engine
drops dead NPCs from the targeting system — reasonable, since corpses are not aim-assist
targets — so strategy A goes blind at exactly the moment a body becomes lootable. A reload
respawns them as already-dead entities, which the query does return.

The fix is to stop choosing between sources and merge them instead. Three now run on every
scan, deduplicated by entity:

- **A, general targeting query** — containers, ground items, pre-existing bodies;
- **B, targeting query filtered to dead/defeated/unconscious puppets** — the states A loses.
  `TSFMV` is a bitfield where the mask bit is `1 << enum value`, so `Obj_Puppet` is 2 and
  dead/defeated/unconscious is `2048 + 8192 + 32768`;
- **C, passive registry** fed by loot marker controllers — whatever the game itself flags
  as loot nearby.

The lesson generalises: no single one of these APIs sees everything, and the one that looks
sufficient in calm play is not the one that matters in combat. The original analysis follows.

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
Risk: the return shape changed between builds. The decompiled scripts show
`[ref<IMappin>]`, which exposes `GetEntityID()`, but the 2.x RTTI definitions show
`gamemappinsMappinEntry` records carrying only `id`, `type` and `worldPosition` — no
entity handle, and therefore nothing to loot. The implementation handles both shapes and
logs which one it actually saw, so this strategy can be deleted outright once confirmed.

**C. Mappin controller hook.** The BetterLootMarkers approach: `ObserveAfter` on
`GameplayMappinController.UpdateVisibility`, then `mappin:GetEntityID()` →
`Game.FindEntityByID()`. Upside: proven in a shipping mod. Downside: passive — the game
calls us rather than us querying it — so it needs its own registry and pruning.

**Decision, and outcome.** All three were implemented as a fallback chain in order
A → B → C, each logging its outcome. The first real run resolved to A. B has since been
deleted: the RTTI evidence above says it cannot work on 2.x, and the run confirmed it never
contributed. C remains as a fallback in case A stops returning results on a future patch,
but its observers stop recording once another strategy is locked in, so it costs nothing
while unused.

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

Confirmed in-game on 2026-08-03: the prompt renders natively and the mod runs without a
single warning. Two details are still worth watching, and both have a switch ready:
- whether re-sending with the same `action` + `source` updates the existing hint or stacks
  a duplicate (plan B: `hintRefreshHack` takes it down with `show=false` and re-sends);
- whether the native hold animation timing matches our threshold — it comes from the
  action's input config, not from us, so `holdTime` can be tuned to match.

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
