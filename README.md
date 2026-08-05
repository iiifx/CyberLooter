# CyberLooter

An accessibility mod for Cyberpunk 2077. Hold one key and everything lootable around you
goes straight into your inventory — no aiming at each corpse, crate and dropped item,
no separate keypress per object.

It was built for players who find repeated precise aiming and clicking painful or
impractical. It is a quality-of-life mod, not a cheat: it only takes what the game would
let you take anyway, using the game's own looting function.

**The mod itself needs only [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks).**
CET in turn runs on RED4ext, so those two are what has to be present in the game — nothing
else. No redscript, no ArchiveXL, no TweakXL, no Codeware, no settings frameworks, and no
other mods. Installing CyberLooter itself is copying one folder.

## What it does

- Hold your chosen key briefly (0.35 s by default) — every lootable object within the
  radius (5 m by default) is emptied into your inventory in one go. Release the key
  immediately; there is nothing to keep holding.
- Works on corpses, containers, stashes and items lying on the ground. Aiming at them is
  not required — the search is by distance, not by line of sight.
- Picks up everything the game allows, junk and broken weapons included. Quest loot is
  skipped by default so that scripted quest objects are never disturbed. Two things are
  never taken: hand-carried heavy weapons, which the game equips into your hands rather
  than your backpack, and vehicle-mounted weapons. Both are invisible in the inventory,
  cannot be dropped or sold, and cost carry weight — see **Remove stuck items** below if a
  save already has some.
- Shows the count of available loot as a **native game button prompt** in the usual place
  on screen (`Loot All · 7`), using the engine's own input-hint system, so it matches the
  game's styling and hold animation. No prompt appears when there is nothing to pick up.
- Stays out of the way: when the game itself shows an interaction prompt (a door, a
  terminal, a corpse you are looking at), the key behaves exactly as it normally does and
  the mod does nothing. A hold that starts during such a prompt is not thrown away though —
  it stays armed and sweeps the moment the prompt goes away, so no re-press is needed.
- If a single hold hits the per-sweep object limit, the rest stays where it is — just
  hold the key again.
- Can also run **hands-free**: switch on automatic looting and the sweep repeats on a
  timer, twice a second by default, with no key at all. It only acts when the scan has
  actually found something nearby, so an empty street costs one cached scan per interval.

## Installation

Nothing here modifies the game's own files. Every piece is a separate file or folder that
can be deleted again, and none of it touches saves or archives.

### Step 0 — find the game folder

Everything below is unpacked into the **game root**: the folder that contains `bin\`,
`archive\` and `REDprelauncher.exe`. On Steam it is usually

```
C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077\
```

If Steam has the game on another drive, use **Steam → right-click Cyberpunk 2077 →
Manage → Browse local files** and it opens exactly this folder.

Getting this wrong is the single most common installation failure. When an archive is
unpacked correctly, its `bin` folder merges into the game's existing `bin` folder — you
should never end up with `Cyberpunk 2077\CyberEngineTweaks\bin\...` or a second nested
`Cyberpunk 2077\Cyberpunk 2077\`.

### Step 1 — RED4ext

Cyber Engine Tweaks runs on top of RED4ext, so this comes first.

1. Download the latest `red4ext-x.y.z.zip` from
   [github.com/WopsS/RED4ext/releases](https://github.com/WopsS/RED4ext/releases)
   (v1.30.0 at the time of writing).
2. Unpack it into the game root. It adds `bin\x64\winmm.dll` and a `red4ext\` folder.

### Step 2 — Cyber Engine Tweaks

1. Download `cet_x.y.z.zip` from
   [github.com/maximegmd/CyberEngineTweaks/releases](https://github.com/maximegmd/CyberEngineTweaks/releases)
   (v1.37.1 or newer). Take the `cet_` archive, not the `-pdb` one — that is debug data.
2. Unpack it into the game root. It adds `bin\x64\version.dll`,
   `bin\x64\plugins\cyber_engine_tweaks.asi`, the `bin\x64\plugins\cyber_engine_tweaks\`
   folder and `bin\x64\global.ini`.

### Step 3 — check that CET works, before going further

Start the game. On the first launch with CET installed, an overlay window appears asking
you to choose the key that opens the CET console and to confirm. Pick one (`~` is the
default suggestion) and accept.

**If that window never appears, stop here** — CET is not loading, and CyberLooter cannot
work until it does. Usual causes:

- the archives went to the wrong folder (see step 0);
- an antivirus quarantined `version.dll` or `winmm.dll` — both are legitimate loader
  libraries, but they look suspicious to some scanners;
- the Microsoft Visual C++ Redistributable (x64) is missing — install it from Microsoft
  and try again.

The CET wiki has a fuller troubleshooting guide:
[wiki.redmodding.org/cyber-engine-tweaks](https://wiki.redmodding.org/cyber-engine-tweaks/).

### Step 4 — CyberLooter

1. Get the mod folder, either by downloading the repository as a ZIP
   (**Code → Download ZIP**) or with git.
2. Copy it into `Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\` and make sure
   the folder is named exactly **`CyberLooter`**. GitHub's ZIP unpacks as
   `CyberLooter-main`, so rename it — CET takes the mod name from the folder name.
3. The result must look like this:

```
Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\CyberLooter\
    init.lua
    version.txt
    Modules\
        Config.lua
        Hint.lua
        ...
```

`init.lua` has to sit directly inside `CyberLooter\`. The `docs\` folder and `README.md`
can stay; they are ignored by the game.

### Step 5 — bind a key

1. Start the game and open the CET overlay.
2. Open the **Bindings** tab and find the **CyberLooter** section.
3. Assign a key to *"CyberLooter: loot everything around"*. The interaction key (`F`) is
   the natural choice and is safe to use — CET does not take the key away from the game,
   so normal interactions keep working.

Until a key is assigned the mod does nothing, and its settings window says so in red.

### Updating and removing

To update, replace the contents of the `CyberLooter` folder; `config.json` and
`cyberlooter.log` live in that same folder, so keep them if you want your settings. If you
installed with git, `git pull` inside the folder is enough.

To remove the mod, delete the `CyberLooter` folder. To remove everything, also delete
`bin\x64\version.dll`, `bin\x64\winmm.dll`, `bin\x64\global.ini`,
`bin\x64\plugins\cyber_engine_tweaks.asi`, `bin\x64\plugins\cyber_engine_tweaks\` and
`red4ext\`.

## Settings

The settings window appears together with the CET overlay. Settings are written to
`config.json` when the overlay is closed.

| Setting | Default | Description |
|---|---|---|
| Radius | 5 m | Pickup radius around the player |
| Hold time | 0.35 s | How long the key must be held to trigger a sweep |
| Max objects per sweep | 24 | Upper bound per activation, to avoid frame hitches |
| Loot automatically, no key needed | off | Sweeps on a timer instead of on a key |
| Sweep every | 0.5 s | How often automatic looting runs, 0.1–3 s |
| Also while driving | off | Whether automatic looting runs while the player is in a vehicle |
| Skip quest loot | on | Leave quest items and quest containers alone |
| Ignore key while a vanilla prompt is up | on | Never interfere with normal interactions |
| Show indicator | on | Show the button prompt when loot is nearby |
| Spell out the bound key in the prompt | off | Adds the assigned key name to the prompt text. Useful when the mod is bound to something other than the interact key, because the key glyph itself always comes from the game's interact action |
| Re-send hint instead of updating | off | Workaround if prompts ever stack up instead of updating |
| ImGui fallback indicator | off | Backup indicator if the engine prompt does not work |
| Offset X / Offset Y | 0 / 60 px | Position of the fallback indicator, shown only when the fallback is enabled |
| Write cyberlooter.log | off | Adds verbose per-scan and per-sweep detail to the log |

`config.json` is created the first time settings are changed and the overlay is closed.

The prompt text is the `hintLabel` field in `config.json` — there is no UI field for it.
It is plain text rendered by the game, so it can be translated, but use characters the
game's current language pack actually has, otherwise you will get empty boxes.

### Automatic looting

With the option on, the sweep runs on its own timer and the key is not needed. It is the
same sweep with the same filters and the same limits — only the trigger changes.

Three things are deliberately different from the manual mode:

- **The button prompt is hidden.** A prompt saying "hold to loot" while the mod is already
  looting would be wrong, and at two sweeps a second it would flicker.
- **The vanilla-prompt guard does not apply.** That guard exists so the mod never acts on
  top of the interact key, and there is no key here. Honouring it would switch automatic
  looting off exactly when it is wanted, because looking at loot is what puts a prompt on
  screen in the first place.
- **A sweep that collects nothing buys silence.** If the scan promises objects and the
  transfer empties none of them — a stuck handle, a container that refuses — retrying twice
  a second would fill the log and cost frames, so the next few seconds are skipped.

Menus, photo mode and loading screens still stop it, and by default so does being in a
vehicle: driving past a district otherwise vacuums up whatever the radius touches.

## How it works

The mod does not implement its own looting. When you press `F` on a corpse, the game runs
exactly one function, and the mod calls that same one:

```
TransactionSystem.TransferAllItems(source, player)
```

Because of that, everything else follows on its own: the loot marker disappears, the
highlight is removed, the object is dropped from the HUD and the "emptied" effect plays —
all of it is driven by the game's own inventory events, not re-implemented here.

There is one exception. If that call visibly moves nothing on some class of object, the
mod falls back to transferring items one at a time and records that in the log. It is an
emergency path, not the normal one, and it exists so that a single unsupported object type
cannot make the mod useless.

The indicator is not drawn by the mod either. It is handed to the engine's own input-hint
system (`Game.SendInputHintData`), which is what renders every vanilla button prompt, so
it matches the game's style, placement and hold animation automatically.

Finding loot around the player is the one part with no single documented API, so three
strategies are implemented and tried in order — targeting system query, mappin system,
and a passive registry fed by loot marker controllers. The first one that works is locked
in for the session and reported in the settings window and the log.

Full technical background, with references to the game's decompiled scripts, is in
[docs/RESEARCH.md](docs/RESEARCH.md); the architecture is in [docs/PLAN.md](docs/PLAN.md).

## Troubleshooting

The mod always keeps a short log in `cyberlooter.log` next to it: startup, the scan
strategy it settled on, sweep results and any failure. Turning on **Write
cyberlooter.log** adds verbose per-scan detail on top of that.

If something misbehaves, turn the switch on, play for a couple of minutes, then look at
`cyberlooter.log` in the mod folder. It records which scan strategy resolved, how many
objects and item stacks were found, what was transferred, which call path was used and
where anything failed.

**Dump inventory to log** writes everything the player is carrying to the log: name,
quantity, weight, equip area, item type, category and tags, heaviest first. The backpack UI
is a view, not the inventory — an item it has no place for is simply not drawn, while its
weight still counts against the carry limit — so this is the way to find out what is really
in there. It reads the inventory and changes nothing in it.

**Remove stuck items** deletes what should never have reached the backpack: vehicle-mounted
weapons and hand-carried heavy weapons. Neither can be seen in the inventory, equipped, sold
or dropped, and both cost carry weight — one session ended 183 kg over the limit on sixteen
of them. The button lists what it found and asks a second time before deleting anything, and
never touches whatever the player currently has equipped. Everything removed is named in the
log. With the current filters nothing new can get stuck, so this is a repair tool for saves
that already have the problem.

The settings window also shows live diagnostics: the assigned key, the active scan
strategy, the current object and stack count in radius, and the result of the last sweep.
It also warns when one of the safety checks cannot run on the current build — an inactive
vanilla-prompt guard or an inactive heavy-weapon filter is called out there in orange
rather than left to be discovered in play.

## Extras: autorun

`extras/autorun.ahk` is a small [AutoHotkey v2](https://www.autohotkey.com/) script that
implements double-tap-forward autorun: tap `W` twice and the character keeps running until
you tap `W` again or press `A`, `S`, `D` or `Escape`. Mouse look and jumping work normally
while it runs.

It is **not part of the mod** and installs nothing into the game — run the file, and quit
it from the tray icon when you are done. Settings are at the top of the file: the forward
key, the double-tap window, the cancel keys and the dodge guard.

That last one matters. Vanilla Cyberpunk already uses double-tap forward for a dodge roll
(`<multitap action="DodgeForward" count="2" uptime="0.2" downtime="0.2" />` in the game's
own `inputContexts.xml`), so the script swallows the second tap and only takes the key over
250 ms later. The game never sees two taps close enough together to dodge, at the cost of a
quarter-second before the character sets off.

Why it is a separate script rather than a feature of the mod: the game's movement axes are
read-only from the scripting side. Locomotion reads them via
`scriptInterface.GetActionValue(n"MoveY")`, and there is no counterpart that writes them,
so no CET mod can move the character by itself. Mods that manage it ship a native C++ DLL
and pull in RED4ext, Redscript, InputLoader and Mod Settings as dependencies. Holding the
key from outside the game achieves the same result with nothing added to the game at all.

## Development

The mod is written on Linux and run on Windows, so nothing can be tried out where it is
written. Two things stand in for that, both in `tests/`:

```
tests/run.sh
```

First it parses every file the game will load, which is the cheapest possible protection
against shipping a mod that fails to start over a typo. Then it runs the specs: the
decision logic — what counts as lootable, what must never be taken, when a sweep may claim
success, when a gate is allowed to keep the mod quiet — against a stand-in for the game
API that refuses the same things the engine refuses.

It needs LuaJIT, the interpreter Cyber Engine Tweaks itself embeds (`sudo apt install
luajit`, or point the runner at your own with `LUA=/path/to/luajit tests/run.sh`).

What these tests can and cannot do is worth being clear about. They pin down the mod's own
reasoning and they lock in the bugs it has already shipped, so those cannot come back
quietly. They cannot discover that a game function behaves differently from what the stub
assumes — that is what the log from a real session is for, and it is why the log is treated
as a first-class feature rather than an afterthought.

The `tests/` folder is inert inside the game: Cyber Engine Tweaks only loads `init.lua`.

## Compatibility

- Written for Cyberpunk 2077 2.3 with Cyber Engine Tweaks v1.37.1, and confirmed working
  there. Every game API it uses was also checked against the game's decompiled scripts and
  the CET source.
- It should coexist with loot marker mods such as BetterLootMarkers: this mod reads marker
  data and never modifies markers itself. Not verified in practice.
- Does not modify save data, game files or archives. Removing the folder removes the mod.

## Status

Working. First in-game pass on 2026-08-03: loot is found and collected, and the prompt
renders as a normal game button hint in the usual place.

What that run established:

- **Loot search** resolves to the targeting-system strategy, which handles corpses,
  containers and ground items alike. A second strategy is kept as a fallback in case a
  future patch breaks the first; the active one is named in the settings window.
- **Every transfer went through the game's own `TransferAllItems`** — the per-item
  emergency fallback was never needed, so in practice the mod loots exactly the way the
  game does.
- **No warnings**, meaning the guard that keeps the key out of the way during normal
  interactions is genuinely active rather than silently disabled.

Still worth knowing: the hold animation is timed by the engine from the interact action's
own configuration, not by `holdTime`. If the bar and the actual trigger ever feel out of
step, tune `holdTime` to match.

## License

MIT — see [LICENSE](LICENSE).
