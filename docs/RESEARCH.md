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

## 12. Which items belong in the player's inventory

Source: the decompiled game scripts, `CDPR-Modding-Documentation/Cyberpunk-Scripts`.

There is no single engine predicate such as `CanItemBeAddedToInventory`. Searching the
whole script dump for one turns up only neighbours of the idea — `RPGManager.CanItemBeDropped`
(rpgManager.script:2960), `CanItemBeDisassembled`, `CanItemTypeBeCompared` — none of which
answers "should the player be carrying this at all".

What exists instead is better, because it is what the game itself acts on: **a tag
blacklist applied at the transaction layer.**

```
UIInventoryItemsManager.GetBlacklistedTags()      inventoryItemsManager.script:445
    'SoftwareShsard'   (CDPR's own typo, in shipped code)
    'TppHead'
    'HideInUI'
    'Currency'
    'Ammo'
    'base_fists'
```

The UI inventory system does not filter these out after the fact. It never loads them:

```
m_transactionSystem.GetItemListExcludingTags( m_attachedPlayer, m_blacklistedTags, playerItems )
                                                  uiInventoryScriptableSystem.script:69
```

`GetItemListExcludingTags` is a native transaction-system function
(transactionSystem.script:47), alongside `GetItemListByTag`, `GetItemListByTags` and
`GetItemListFilteredByTags`. The same file's `IsBackpackItem` logic
(uiInventoryScriptableSystem.script:477-486) computes exactly this from `itemRecord.Tags()`.
The backpack screen adds one more tag of its own:

```
tagsToFilterOut.PushBack( 'HideInBackpackUI' )     backpack_main.script:439
tagsToFilterOut.PushBack( 'SoftwareShard' )
```

So an item tagged `HideInUI` or `HideInBackpackUI` is not merely hidden — it never enters
the player's item map, which is why one cannot be seen, equipped, sold, dropped or
disassembled, while its weight still counts. That is precisely the failure the player hit:
an inventory 205 units into a 200 unit limit, with nothing visible to remove.

`HideInBackpackUI` must not be treated as "do not loot" either, and this one cost real
damage before it was understood. It does not mean "not a real item"; it means "this screen
is not where this item lives". Installed cyberware carries it, because cyberware is shown on
its own screen. The mod briefly refused it, the cleanup tool inherited that judgement, and a
player lost every implant in their body. Only `HideInUI` means invisible everywhere.

Two more of the six blacklisted tags must **not** be treated as "do not loot". `Currency` and
`Ammo` are hidden from the backpack because they have their own counters, not because they
are unwanted. The mod therefore refuses `HideInUI`, `TppHead` and `base_fists`, and takes money,
ammunition and cyberware as before.

### Vehicle weapons

`gamedataItemType` has two dedicated members — `Wea_VehiclePowerWeapon` and
`Wea_VehicleMissileLauncher` (tweakDBEnums.script:148-149) — and every use of them in the
scripts is an explicit comparison (vehicleTransition.script:2588, weaponRoster.script:337,
damageSystem.script:3077). There is no "is this a vehicle weapon" helper: CDPR does compare
against the enum by hand, which was worth confirming rather than assuming.

Whether `Items.Vehicle_Power_Weapon_Left_A` also carries `HideInUI` cannot be answered from
the script dump, because TweakDB item data is not part of it. The mod's inventory dump now
prints each item's tags, so the next log from a real session settles it. Until then both
rules are in place: the tag test, and a record-path match on `Items.Vehicle_`.

### What this does not settle

The heavy-weapon case is separate and stays as it is. A `WeaponHeavy` weapon is a perfectly
normal item that the game equips into the player's hands through
`LootPickupScriptedCondition` (scriptedConditions.script:383) rather than into the backpack;
it is not tag-blacklisted, and it broke the player's character state when moved as loot.

---

## 13. When is a body lootable

`ScriptedPuppet.IsActive` (scriptedPuppet.script:1939, `IsActiveInternal` at :1950) is the
engine's own test, and it is a conjunction of five:

```
not IsDeadNoStatPool() and not IsDefeated() and not IsUnconscious()
    and not IsTurnedOffNoStatusEffect() and not IsIncapacitated()
```

`IsDefeated` and `IsUnconscious` (:1849, :1866) are status-effect queries, not health
checks, which is why a knocked-out enemy fails none of the health tests while being just as
lootable as a corpse. The game gates the loot highlight on the same value
(`GetDefaultHighlight`, :4771: `!IsActive() && !HasLootableItems(...)`).

`IsDead()` (:1981) reads the health stat pool, while `IsDeadNoStatPool()` (:1988) reads the
persistent state flag — they are not interchangeable, and neither one alone answers the
question.

---

## 14. Verified API signatures

Checked against the RTTI dump in `Bradenm1/Cyberpunk2077-Inspector` (`Dumps/*.lua`), which
lists the native functions of each class, and against the decompiled scripts for anything
script-defined. Three of the mod's calls were wrong, and all three failed silently because
every game call here is wrapped in `pcall`.

| Call | Verdict |
|---|---|
| `TransferAllItems(source, target) -> Bool` | correct |
| `TransferItem(source, target, itemID, amount) -> Bool` | correct |
| `RemoveItem(obj, itemID, amount) -> Bool` | correct |
| `GetItemList(obj) -> Bool, array<gameItemData>` | correct |
| `GetTotalItemQuantity(obj) -> Int32` | correct |
| `IsSlotted(obj, itemID)` | **does not exist** — the call is `HasItemInAnySlot(obj, itemID) -> Bool` |
| `gameItemData:GetStatValueCurrent(stat)` | **does not exist** — the call is `GetStatValueByType(stat) -> Float` (minimalItemTooltipData.script:178) |
| `RPGManager.GetItemWeight(itemData) -> Float` | correct, script-defined (rpgManager.script:1385) |
| `RPGManager.GetItemRecord(itemID) -> Item_Record` | correct, script-defined (rpgManager.script:2874) |
| `ScriptedPuppet.IsActive(obj)` | correct as a script static (:1939); `obj:IsActive()` also exists natively |

The lesson is about the `pcall` wrapper rather than about the two typos. Wrapping every game
call means a misspelled function is indistinguishable from a function that answered "no",
so a guard can be dead for its entire life while reporting that it works. Both defects above
were of exactly that kind: the equipped-item guard on a destructive button, and the fallback
path for reading item weight. Any probe that cannot answer must now say so and fail toward
the safe side, not quietly return `false`.

### TSFMV bit values

`TSFMV` (targetingSearchFilter.script:13-33) has no explicit values, so the mask arithmetic
rests on the members being powers of two. They are: the game's own code writes
`TSFMV.Obj_Puppet | TSFMV.St_Alive` (:73), which is meaningless for ordinals. Index order
gives `Obj_Puppet` = 2, `St_Dead` = 2048, `St_Defeated` = 8192, `St_Unconscious` = 32768,
`St_TurnedOff` = 131072 — the last of which the corpse query was missing, so shut-down
robots were never asked for.

---

## 15. How a published mod solves the same problem

Reference: **Autoloot** by keanuWheeze (mirror `raikoug/Cyberpunk-Mod---Autoloot`), `modules/logic.lua`.
It is the closest shipped equivalent and has years of bug reports behind it. Two structural
differences are worth stating plainly.

**It never calls `TransferAllItems`.** Every item goes through a per-item transfer, so every
item passes a filter. CyberLooter uses the bulk call as its primary path and only falls back
to per-item when something in the object must be left behind. The bulk call is what the game
itself runs on a corpse, which is why it is kept — but it means a filter mistake is a filter
that never runs, not a filter that lets one item through.

**It blacklists device classes rather than accepting anything with an inventory.**
`modules/logic.lua:679-742` excludes about sixty classes by name — `Stash`, `Wardrobe`,
`DropPoint`, `VendingMachine`, `AccessPoint`, `Computer`, turrets, screens, doors. This mod
took the opposite approach ("does it hold items?") after a class whitelist proved too narrow,
and that inversion was one step away from emptying the player's apartment stash into their
backpack: `Stash extends InteractiveDevice extends Device` (stash.script:39) with a real
inventory component. Devices are now rejected by base class, with a name list behind it.

Other protections it has that this mod does not, listed honestly rather than adopted
wholesale:

| Autoloot | Here |
|---|---|
| `testedSet = Visible` + frustum + LOS raycast (logic.lua:598-677) | `Complete` — loots through walls, kept deliberately: aiming is exactly what this mod exists to avoid |
| `gameObj:IsLocked(player)` (logic.lua:816) | now checked too |
| ~17 hardcoded world coordinates of quest-breaking pickups (logic.lua:76-94) | not present |
| Keycard and iconic-weapon protection (logic.lua:814, 823-842) | not present |
| Quest-phase and workspot/dialog/braindance blocklist (logic.lua:1094-1171) | not present |
| Loots an NPC only if dead, defeated, or it has a killer (logic.lua:771-779) | any inactive puppet |

The coordinate list is the telling one: those items are not `IsQuest()`-flagged, which is
precisely why a hardcoded list exists. Any mod relying on `IsQuest()` alone — this one — can
break those quests.

---

## 16. Why the credit chip was never picked up — VERIFIED

The item is `Items.MoneyShard`, and the game's own data says plainly why the mod refused it.
`Cyberpunk-Tweaks/tweaks/base/gameplay/static_data/database/items/misc/currency.tweak`:

```
MoneyShard : Item
{
  itemType = "ItemType.Gen_MoneyShard";
  displayName = "LocKey#93437";
  iconPath = "q003_chip";
  tags = [ "MoneyShard", "HideInUI", "SkipActivityLog", "HideInBackpackUI" ];
}
```

`HideInUI` is on the mod's refusal list (§12), so every money shard in the game was
classified as untouchable junk. Worse than the missed pickup: an object holding a shard
alongside ordinary loot was marked as mixed, which forces the item-by-item path instead of
the bulk `TransferAllItems` the game itself uses.

The tag is not a mistake in the game's data, and it is not a reason to leave the shard
either. `PlayerPuppet.OnItemAddedToInventory` (`player.swift:2091`, the money branch at
`:2277`) does this the moment the shard arrives:

```swift
if Equals(itemType, gamedataItemType.Gen_MoneyShard) {
  price = RPGManager.CalculateSellPrice(this.GetGame(), this, evt.itemID) * evt.itemData.GetQuantity();
  transSystem.GiveMoney(this, price, n"money");
  transSystem.RemoveItem(this, evt.itemID, transSystem.GetItemQuantity(this, evt.itemID));
};
```

So the shard turns into eddies and deletes itself before any screen could show it. That is
why it is hidden, and it is also why it can never become stuck — which is the only hazard
the `HideInUI` rule exists to prevent. Vanilla `F` on a corpse takes it through the same
`TransferAllItems`, so nothing about this path is new.

**Is the class wider than one item?** Checked: 45 files in the tweak database mention
`HideInUI`, and the others are genuine internals — the `Left_Hand` weapon variants,
`DummyPart` attachments, `PropItem`, cyberware fragments. Those must stay refused. The money
shard is the only family the game consumes on arrival, so the exemption is one predicate
wide: tag `MoneyShard` or item type `Gen_MoneyShard`, asked as two separate probes because
either one on its own settles it.

## 17. Opening a door the way the game does — VERIFIED

**The action.** Pressing `F` on a door runs `ToggleOpen`. `DoorController.GetActions`
(`doorController.swift:482-489`) pushes `GetPlayerToggleOpenAction()` → `ActionToggleOpen()`
(`:675`), and `OnToggleOpen` (`:703`) is what actually moves the door.

The game also queues that action itself, and this is the exact shape to copy
(`doorController.swift:1341`):

```swift
actionClose = this.ActionToggleOpen();
actionClose.SetExecutor(evt.GetExecutor());
actionClose.RegisterAsRequester(PersistentID.ExtractEntityID(this.GetID()));
this.GetPersistencySystem().QueuePSDeviceEvent(actionClose);
```

All four calls are reachable from Lua: `DoorControllerPS:ActionToggleOpen`,
`BaseScriptableAction:SetExecutor` / `:RegisterAsRequester`,
`gamePersistencySystem:QueuePSDeviceEvent`. The published `unlockNightCity` mod drives
devices through `QueuePSDeviceEvent` the same way, so the route is proven outside the game's
own code as well. The requester id is taken straight off the door entity instead of through
`PersistentID.ExtractEntityID`, which is the same value without the extra dependency.

**Deliberately not `Door.OpenDoor()`** (`door.swift:794`), even though it is the shorter
call and a shipped mod uses it. It goes through `ActionSetOpened`, and `OnSetOpened`
(`doorController.swift:754`) refuses only sealed and disabled doors — a locked door opens.
That is a lockpick, which is a different mod.

**The condition.** `Door.EvaluateOffMeshLinks` (`door.swift:128-150`) is the game deciding
whether navigation may route through a door, and its "openable without effort" branch reads:

```swift
if ps.IsClosed() {
  ...
  if !ps.IsLocked() && !ps.IsDeviceSecured() && !this.HasAnySkillCheckActive() && ps.IsON() {
```

with `IsDisabled() || IsSealed() || IsUnpowered()` ruled out above it. Same questions, same
order — so the feature can never offer more than the game already does. `IsLiftDoor()` and
`GetDoorType()` (`EDoorType.AUTOMATIC`, `REMOTELY_CONTROLLED`) exclude the doors that answer
to something other than the player, and `Window` / `MovableWallScreen` are excluded by class:
both extend `Door` and would otherwise be swept along.

**Combat.** Two independent signals. `PlayerPuppet.IsInCombat()` is the engine's own cached
answer (`player.swift`), and the player state machine blackboard carries the same thing as
`gamePSMCombat`: `Default 0, InCombat 1, OutOfCombat 2, Stealth 3`. The game compares that
field against the literal `1` (`activityCardsHelper.script`), so the number is read the same
way rather than through an enum member that may not resolve. Stealth is its own state and is
not combat.

**Which door.** `gametargetingTargetingSystem:GetLookAtObject(instigator, withLOS,
ignoreTransparent)` returns the object under the cursor — the same thing that puts the
prompt on screen. Unlike the loot search, which deliberately ignores where the player is
looking, a door is large enough to face without aiming, and a radius sweep would open every
door in a corridor.

**Two states must be certain, the rest need not be.** `IsClosed`, `IsLocked` and `IsSealed`
are refused when unreadable: the action is a toggle, so a wrong "closed" would close a door
the player just opened, and a wrong "locked" would break the only promise this feature
makes. Everything else only predicts whether the queued action would have succeeded, and the
game refuses it harmlessly if not — so an unreadable answer there does not veto. This is the
§14 lesson applied deliberately rather than uniformly: a probe that cannot answer must fail
toward the safe side, and which side is safe depends on the question.

---

## Risk summary

| Risk | Assessment | Mitigation |
|---|---|---|
| Loot around the player is not found | Medium | Three strategies with fallback, plus logging |
| `TransferAllItems` fails on containers or ground items | Low | Confirmed by game code for corpses; elsewhere, verified by emptiness check with per-item fallback |
| Conflict with the vanilla interact key | Low | `InteractionChoiceHub` check before acting |
| Frame drops at large radius | Low | Throttled scanning, per-sweep object cap |
| Broken quest | Low | `IsQuest()` filter, on by default |
| Inventory filling with junk | Certain | A deliberate user choice |
| Items that cannot be seen or dropped | Handled | Refused by the game's own tag blacklist (§12); a cleanup tool exists for saves that already have some |
| A door opens when it should not | Low | Off by default; the game's own openability condition (§17), and the two states that could make the toggle harmful must be readable or nothing happens |
| A door opens during a fight | Low | Two independent combat signals; neither readable means the feature stays silent and says so |
