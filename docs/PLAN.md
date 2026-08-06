# CyberLooter — implementation plan

An accessibility mod for Cyberpunk 2077: loot everything within a radius around the player
by holding a single key.

## Requirements

1. A sweep triggers on **holding** the key, not on a single press. No key is bound by
   default — CET bindings start empty — and the interact key (`F`) is the recommended choice.
   The hold is short (~0.35 s threshold) and the sweep is one-shot — the key can be
   released immediately, there is nothing to keep holding.
2. It only triggers when **no vanilla action is bound to the key at that moment**.
   Looking at a door or a corpse means the key behaves normally and the mod stays silent.
3. The radius is configurable, 5 metres by default.
4. The **indicator** appears only when there is genuinely something to pick up, and looks
   like an ordinary in-game button prompt: same place on screen, same style, native hold
   animation. The number of available stacks is part of the prompt text (`Loot All · 7`).
   No loot, no prompt. Rendered by the engine rather than drawn by us (see RESEARCH §10).
5. Pick up **everything** the game allows, junk and broken weapons included. The single
   exception is quest loot (switchable in settings).
6. Loot through the **game's own mechanism**, not a raw item transfer.
7. **Minimal dependencies.** Cyber Engine Tweaks and nothing else.
8. **English only** across code, comments and documentation.
9. **MIT licensed.**

## Dependencies

Exactly one: **Cyber Engine Tweaks** (current release v1.37.1). CET itself is built on
RED4ext, so the player needs RED4ext + CET in the game — but the mod never talks to
RED4ext directly and would keep working if CET changed its own foundation.

Not used and not required: redscript, ArchiveXL, TweakXL, Codeware, Mod Settings,
Native Settings UI. Settings live in an own ImGui window and an own `config.json`.
Installing the mod is copying one folder.

## Flow

```
Player holds the key
   │
   ├─ vanilla interaction active?  ──yes──> do nothing, the key behaves normally
   │  (UIInteractions.InteractionChoiceHub.choices is non-empty)
   │
   ├─ hold reached the threshold (0.35 s)?  ──no──> wait / reset on release
   │
   ▼
Scan the radius (5 m) ──> list of objects holding loot
   │
   ├─ filter: empty, quest (if enabled), not lootable
   │
   ▼
For each object: TransactionSystem:TransferAllItems(object, player)
   │
   ▼
The game itself: clears the marker, drops the highlight, removes the HUD entry
```

The prompt is independent of the sweep: a background scan runs every ~0.3 s, and whenever
something is found the engine is handed a `Loot All · N` hint with the hold animation
enabled. When the loot is gone, the hint is withdrawn.

Every technical decision is justified in [RESEARCH.md](RESEARCH.md).

## Layout

```
CyberLooter/
├── init.lua              entry point, CET event registration
├── config.json           created on first settings save
├── version.txt
├── LICENSE               MIT
├── README.md             installation and usage
├── docs/
│   ├── RESEARCH.md       game API research results
│   └── PLAN.md           this file
└── Modules/
    ├── Config.lua        settings, load/save, ImGui window
    ├── State.lua         game state gates — when the mod must keep quiet
    ├── Input.lua         hold timing, threshold, state
    ├── Auto.lua          hands-free sweeps on a timer
    ├── Scanner.lua       radius search (three strategies with fallback)
    ├── Looter.lua        filtering and item transfer
    ├── Hint.lua          button prompt via the engine's own hint system
    ├── Hud.lua           fallback ImGui indicator
    └── Log.lua           diagnostic log file
```

## Modules

### Config.lua

| Setting | Default | Range |
|---|---|---|
| `radius` | 5.0 m | 2–25 |
| `holdTime` | 0.35 s | 0.1–1.5 |
| `skipQuestItems` | on | — |
| `respectInteraction` | on | — |
| `maxObjectsPerSweep` | 24 | 4–100 |
| `autoLoot` | off | — |
| `autoLootInterval` | 0.5 s | 0.1–3.0 |
| `autoLootInVehicle` | off | — |
| `showIndicator` | on | — |
| `hintShowKeyName` | off | — |
| `hintLabel` | `Loot All` | free text |
| `hintRefreshHack` | off | — |
| `useImGuiFallback` | off | — |
| `indicatorOffsetX` | 0 px | −800…800 |
| `indicatorOffsetY` | 60 px | −600…600 |
| `debugLog` | off | — |

The window opens with the CET overlay; settings are written to `config.json` on close.
Loading only accepts known keys whose type matches the declared default.

### State.lua

A single gate shared by the sweep and the indicator, so the prompt never promises
something the sweep would refuse to do. Blocks on: no player, fullscreen menu
(`UI_System.IsInMenu`), photo mode, and — when `respectInteraction` is on — a live vanilla
interaction (`UIInteractions.InteractionChoiceHub.choices`).

The blackboard returns a Variant, which has to be unpacked with `FromVariant` before its
fields exist; both the packed and already-unpacked shapes are accepted. If the read fails
outright, the mod keeps working (failing closed would disable it entirely) but says so
loudly once in the log and permanently in the settings window, because a silently inactive
guard is worse than a missing one.

A hub is only believed while it looks alive: an explicit `active == false` counts as no
prompt, and an unchanged hub signature (`id/title/hubPriority/choice count`) that has been
reported for more than 20 s is treated as leftover blackboard data, with a warning. The gate
is the one thing that can silence the whole mod, so it is not allowed to do so forever on
the strength of a value nothing is guaranteed to clear.

Every gate refusal is timed. When scanning has been suppressed for 10 s or more, the reason
is written to the log at INFO level, and so is the moment it resumes — otherwise a mod that
has stopped looking is indistinguishable from a world with nothing to loot in it, which is
exactly how the 0.2.4 outage presented.

### Input.lua

`registerInput("cyberlooter_sweep", ...)` with an `isDown` callback. Press records the
moment, `onUpdate` accumulates the duration, reaching `holdTime` fires exactly one sweep
and blocks repeats until release. `IsBound`/`GetBind` drive the "no key assigned" warning
and the key name in the fallback indicator.

The gate is evaluated before the hold is consumed, so a hold that lands while a vanilla
prompt is up stays live and fires the moment the gate opens, rather than being burned and
requiring a fresh press.

Registration happens at load time, never from `onInit` — see RESEARCH §11.

### Auto.lua

The same sweep on a timer instead of on a key, for players who cannot comfortably hold one.
Gated on menu, photo mode and — unless the player says otherwise — being in a vehicle, which
is read from `PlayerStateMachine.MountedToVehicle`, the same field
`VehicleSystem.IsPlayerInVehicle` uses.

Not gated on the vanilla interaction prompt, and that is the one deliberate asymmetry with
the manual path: the gate exists so a key press never lands on top of an interaction, and
there is no key here. Keeping it would disable automatic looting precisely when loot is in
front of the player, since that is what raises a prompt.

A sweep that collects nothing despite a non-empty scan pauses the loop for three seconds.
Without that, an object that cannot be emptied is retried twice a second for as long as the
player stands near it.

### Audit.lua

Reads the player's inventory through the transaction system rather than the backpack UI,
because the UI is a view and hides whole families of item. The dump reports name, weight,
stack size, equip area, item type, category and tags, heaviest first.

The cleanup uses `Scanner.IsStuckInInventory`, which is **not** the pickup filter and must
never become it. The pickup filter answers "is this worth taking" and errs toward taking
less; the cleanup answers "may this be destroyed" and must err toward destroying nothing. It
recognises only hand-carried weapons and `Items.Vehicle_` hardware, and refuses cyberware,
quest items and anything unclassifiable — refusing on an unreadable answer rather than
proceeding.

That separation is not theoretical. The first version reused the pickup filter, which had
just been taught that `HideInBackpackUI` marks junk. Installed cyberware carries that tag,
because cyberware belongs on the cyberware screen and not in the backpack, so the button
deleted every implant in the player's body.

### Scanner.lua

Three sources run on every scan and their results are merged, deduplicated by entity id.
The contributing sources are named in the log and in the settings window:

1. `TargetingSystem:GetTargetParts` with a general `TargetSearchQuery` (`maxDistance` =
   radius, `testedSet = gameTargetingSet.Complete`);
2. the same call with a filter for dead, defeated and unconscious puppets — the engine
   removes dead NPCs from the general query, so without this one corpses from a fight in
   progress stay invisible until a reload;
3. a passive registry fed by `GameplayMappinController` observers.

Merging rather than picking one is deliberate: none of these sees everything, and the gap
in the general query only shows up in combat. See RESEARCH §9.

A fourth source over `MappinSystem:GetMappins` was implemented and then deleted: on
game 2.x it returns records with no entity handle.

Candidate filtering rejects the player, vehicles and living NPCs outright, accepts corpses
and the known loot classes (`gameItemDropObject`, `gameLootBag`, `gameLootContainerBase`
and everything deriving from it), and then falls back to a simple question for anything
else: does it hold items? A class whitelist was the original design and it silently
discarded items lying on tables and inside furniture, so the inventory is now the test.

Before any of that, the holder is resolved. An item in the world is a visual
`gameItemObject`; its inventory lives on the item drop it is connected to, reachable via
`GetConnectedItemDrop()` (`GetOwner()` alone does not find it). Objects with no items are
dropped, distance is `Vector4.Distance` to the player.

With the debug log on, every discarded object is counted by class name, so a future miss
identifies itself rather than needing another investigation.

Entities can go stale between the world query and the filtering pass, so every handle
access there is individually protected — one dead handle must not abort a scan that runs
several times per second.

Results are cached for 0.3 s so the indicator does not query the world every frame. The
marker registry that strategy 3 feeds on is pruned on its own 30 s schedule rather than
from inside the strategy, because the observers keep filling it no matter which strategy
ended up being selected.

Quest loot is filtered per item, not per object. The first version rejected the whole
holder if any item in it was quest-tagged, which meant a body carrying one quest item gave
up nothing at all — and since the decision only reached the debug log, it presented as a
single corpse that refused to be looted while everything around it worked. Vanilla `F` on
that same body takes the ordinary items, and the mod now matches it. A holder whose own
`IsQuest()` is true is still skipped whole: that is a scripted object, not a container that
happens to hold a quest item.

Every scan publishes why nearby loot was left alone — quest objects, skipped stacks,
objects skipped entirely — and the settings window shows it live, so "there is loot here
and the mod is not taking it" is answerable while standing next to the thing.

### Looter.lua

Per object: quest check, restricted-content check, then
`TransactionSystem:TransferAllItems(holder, player)`.

Restricted items are those that must never reach the backpack. Two families: weapons the
game equips into the player's hands rather than into the inventory, identified by the
`WeaponHeavy` equip area, the machine-gun item types or the `DiscardOnEmpty` tag; and
anything the game's own inventory system refuses to load, identified by the tags
`HideInUI`, `HideInBackpackUI`, `TppHead` and `base_fists` (RESEARCH §12) — the same test
the backpack applies through `GetItemListExcludingTags`, minus `Currency` and `Ammo`, which
are hidden for having their own counters rather than for being unwanted; and vehicle-mounted
hardware, identified by an `Items.Vehicle_` record path. The second family
declares the ordinary `Weapon` equip area and is indistinguishable from a real gun by any
other field observed so far, which is why a name match is used — bluntly, but exactly. The
verdict is memoised per record path, both because it cannot change during a session and
because reading the path is a debug-facing call on a per-frame code path. Bulk-transferring one leaves the player stuck in the
carrying pose holding an invisible weapon, so an object that also holds ordinary loot goes
item by item instead, and an object holding nothing else is skipped entirely.

Each of those three signals is probed separately and an unanswerable one counts as "not
restricted". The first implementation did the opposite — one `pcall` around all three, any
error meaning restricted — and that turned a single unavailable API into a total outage:
every item in the game was classified restricted, so every object reported zero lootable
stacks and the mod went silently blind. Failing open loses one filter; failing closed loses
the mod. When no signal at all can be evaluated, a warning goes to the log and the settings
window says the heavy-weapon filter is inactive, so the weaker guarantee is visible rather
than assumed. The per-scan debug line also reports how many stacks were classed restricted,
which is what makes this failure mode obvious at a glance.
Success is judged by the object actually emptying — `GetTotalItemQuantity` before and
after — because that is the only honest signal available.

The quantity check has three edge cases that are handled explicitly rather than lumped in
with failure: an object already empty before the call (the scan cache is up to 0.3 s old)
is neither success nor failure; a quantity of `-1` afterwards means the object despawned
once emptied, so an error-free call is taken at its word and marked `unverified` in the
log; only a genuinely unchanged, readable quantity triggers the per-item
`GetItemList` + `TransferItem` fallback. That fallback counts only transfers that returned
true, so it cannot report loot it never moved.

Capped at `maxObjectsPerSweep` objects per sweep; every call is wrapped in `pcall`.

### Hint.lua — primary path, engine-rendered

```lua
local hint = gameuiInputHintData.new()
hint.action = CName.new("Choice1")            -- engine picks the key glyph
hint.source = CName.new("CyberLooter")        -- our id, also used to withdraw it
hint.localizedLabel = "Loot All · 7"
hint.holdIndicationType = inkInputHintHoldIndicationType.Hold
hint.enableHoldAnimation = true
Game.SendInputHintData(true, hint, "GameplayInputHelper")
```

- **The number** counts stacks, not units: 45 rounds of ammo is one entry, otherwise the
  number turns three-digit and useless.
- **Withdrawing** is the same call with `show = false`.
- **Updating** re-sends with new text. Should the engine stack duplicates instead of
  updating (assumption, RESEARCH §10), `hintRefreshHack` takes it down first.
- **Key glyph.** It always comes from `action = "Choice1"`, because the hint system
  renders the glyph from the action and will not draw a prompt without one. That is correct
  while the binding sits on the interact key; for any other key, `hintShowKeyName` adds the
  real key name to the text so the prompt does not mislead.
- **Liveness.** The engine can drop its hint container without telling us (save load,
  fast travel, UI rebuild), so the hint is re-sent every few seconds even when the text has
  not changed. Cheap, and it heals a prompt that silently disappeared.
- If the engine call fails at all, the module says so once and raises its own runtime
  fallback flag. It deliberately does not write to the user's settings, so a one-off
  failure cannot end up saved in `config.json`.

### Hud.lua — fallback path, ImGui

Enabled by `useImGuiFallback`, or automatically when the engine hint path has failed this
session. `onDraw` runs with the overlay closed (RESEARCH §8). A borderless,
background-less, input-less window: the bound key, the count, and frame brightness as hold
progress. Position is a configurable offset from screen centre, obtained via CET's
`GetDisplayResolution()`.

### Log.lua

Writes `cyberlooter.log` next to the mod: which scan strategy resolved, how many objects
were found and processed, which transfer path was used, what failed and why.

Info, warnings and errors are always written - there are only a handful of them per
session and they are what makes a bug report usable. The `debugLog` switch adds verbose
per-scan and per-sweep detail. Repeated messages are throttled so per-frame paths cannot
flood the file. This file is the primary feedback channel in place of in-game debugging.

## Testing constraints

Development happens on Linux; the game runs on the user's Windows machine. The game cannot
be launched where the code is written. Therefore:

- every uncertain call is wrapped in `pcall` and logged;
- every critical operation has a fallback path;
- the first deployment must yield maximum information even if it fails completely.

Realistic expectation: two to three deploy → log → fix rounds before it is stable.
