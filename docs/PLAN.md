# CyberLooter — implementation plan

An accessibility mod for Cyberpunk 2077: loot everything within a radius around the player
by holding a single key.

## Requirements

1. A sweep triggers on **holding** the key (`F` by default), not on a single press.
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

## Dependencies

Exactly one: **Cyber Engine Tweaks** (current release v1.37.1).

Not used and not required: redscript, RED4ext, ArchiveXL, TweakXL, Codeware, Mod Settings,
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
| `showIndicator` | on | — |
| `hintUseGameAction` | on | — |
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

### Input.lua

`registerInput("cyberlooter_sweep", ...)` with an `isDown` callback. Press records the
moment, `onUpdate` accumulates the duration, reaching `holdTime` fires exactly one sweep
and blocks repeats until release. `IsBound`/`GetBind` drive the "no key assigned" warning
and the key name in the fallback indicator.

Registration happens at load time, never from `onInit` — see RESEARCH §11.

### Scanner.lua

Three strategies, tried in order; the first one that returns lootable objects is locked in
for the session and named in the log and the settings window:

1. `TargetingSystem:GetTargetParts` with a `TargetSearchQuery` (`maxDistance` = radius,
   `testedSet = TargetingSet.Complete`);
2. `MappinSystem:GetMappins(...)`;
3. a passive registry fed by `GameplayMappinController` observers.

Candidate filtering: `gameItemDropObject`, `gameLootBag`, `gameLootContainerBase`,
`gameContainerObjectBase`, `ContainerObjectSingleItem`, and `ScriptedPuppet` only when
dead or defeated. A dropped item is an `ItemObject` whose owner holds the inventory, so the
holder is resolved before anything else. Objects with no items are dropped, distance is
`Vector4.Distance` to the player.

Results are cached for 0.3 s so the indicator does not query the world every frame.

### Looter.lua

Per object: quest check, then `TransactionSystem:TransferAllItems(holder, player)`.
Success is judged by the object actually emptying — `GetTotalItemQuantity` before and
after — because that is the only honest signal available. If nothing moved, it falls back
to per-item `GetItemList` + `TransferItem` and records that in the log. Capped at
`maxObjectsPerSweep` objects per sweep; every call is wrapped in `pcall`.

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
- **Key glyph.** `action = "Choice1"` is correct while our binding sits on the interact
  key. `hintUseGameAction` turns that off and spells the assigned key out in the text.
- If the engine call fails at all, the module says so once and switches to the ImGui path.

### Hud.lua — fallback path, ImGui

Enabled by `useImGuiFallback`. `onDraw` runs with the overlay closed (RESEARCH §8).
A borderless, background-less, input-less window: the bound key, the count, and frame
brightness as hold progress. Position is a configurable offset from screen centre.

### Log.lua

Writes `cyberlooter.log` next to the mod: which scan strategy resolved, how many objects
were found and processed, which transfer path was used, what failed and why. Off by
default. Repeated messages are throttled so per-frame paths cannot flood the file.
This file is the primary feedback channel in place of in-game debugging.

## Testing constraints

Development happens on Linux; the game runs on the user's Windows machine. The game cannot
be launched where the code is written. Therefore:

- every uncertain call is wrapped in `pcall` and logged;
- every critical operation has a fallback path;
- the first deployment must yield maximum information even if it fails completely.

Realistic expectation: two to three deploy → log → fix rounds before it is stable.
