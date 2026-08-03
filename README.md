# CyberLooter

An accessibility mod for Cyberpunk 2077. Hold one key and everything lootable around you
goes straight into your inventory — no aiming at each corpse, crate and dropped item,
no separate keypress per object.

It was built for players who find repeated precise aiming and clicking painful or
impractical. It is a quality-of-life mod, not a cheat: it only takes what the game would
let you take anyway, using the game's own looting function.

**One dependency: [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks).**
No redscript, no RED4ext, no ArchiveXL, no TweakXL, no Codeware, no settings frameworks.
Installing the mod means copying one folder.

## What it does

- Hold your chosen key briefly (0.35 s by default) — every lootable object within the
  radius (5 m by default) is emptied into your inventory in one go. Release the key
  immediately; there is nothing to keep holding.
- Works on corpses, containers, stashes and items lying on the ground. Aiming at them is
  not required — the search is by distance, not by line of sight.
- Picks up everything the game allows, junk and broken weapons included. Quest loot is
  skipped by default so that scripted quest objects are never disturbed.
- Shows the count of available loot as a **native game button prompt** in the usual place
  on screen (`Loot All · 7`), using the engine's own input-hint system, so it matches the
  game's styling and hold animation. No prompt appears when there is nothing to pick up.
- Stays out of the way: when the game itself shows an interaction prompt (a door, a
  terminal, a corpse you are looking at), the key behaves exactly as it normally does and
  the mod does nothing.
- If a single hold hits the per-sweep object limit, the rest stays where it is — just
  hold the key again.

## Installation

1. Install Cyber Engine Tweaks (v1.37.1 or newer).
2. Copy the `CyberLooter` folder into
   `Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\`.
3. Start the game and open the CET overlay (`~` by default).
4. Go to the **Bindings** tab, find the **CyberLooter** section and assign a key to
   *"CyberLooter: loot everything around"*. The interaction key (`F`) is the natural
   choice and is safe to use — CET does not take the key away from the game.

Until a key is assigned the mod does nothing, and its settings window says so.

## Settings

The settings window appears together with the CET overlay. Settings are written to
`config.json` when the overlay is closed.

| Setting | Default | Description |
|---|---|---|
| Radius | 5 m | Pickup radius around the player |
| Hold time | 0.35 s | How long the key must be held to trigger a sweep |
| Max objects per sweep | 24 | Upper bound per activation, to avoid frame hitches |
| Skip quest loot | on | Leave quest items and quest containers alone |
| Ignore key while a vanilla prompt is up | on | Never interfere with normal interactions |
| Show indicator | on | Show the button prompt when loot is nearby |
| Use game key icon | on | Borrow the key glyph from the game's interact action |
| Re-send hint instead of updating | off | Workaround if prompts ever stack up instead of updating |
| ImGui fallback indicator | off | Backup indicator if the engine prompt does not work |
| Offset X / Offset Y | 0 / 60 px | Position of the fallback indicator, shown only when the fallback is enabled |
| Write cyberlooter.log | off | Verbose diagnostic log |

`config.json` is created the first time settings are changed and the overlay is closed.

The prompt text is the `hintLabel` field in `config.json` — there is no UI field for it.
It is plain text rendered by the game, so it can be translated, but use characters the
game's current language pack actually has, otherwise you will get empty boxes.

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

Turn on **Write cyberlooter.log**, play for a couple of minutes, then look at
`cyberlooter.log` in the mod folder. It records which scan strategy resolved, how many
objects and item stacks were found, what was transferred, which call path was used and
where anything failed.

The settings window also shows live diagnostics: the assigned key, the active scan
strategy, the current object and stack count in radius, and the result of the last sweep.

## Compatibility

- Written against Cyberpunk 2077 2.3 and Cyber Engine Tweaks v1.37.1. Every game API it
  uses was checked against the game's decompiled scripts and the CET source, but the mod
  has not yet been through a full in-game test pass — see the status note below.
- It should coexist with loot marker mods such as BetterLootMarkers: this mod reads marker
  data and never modifies markers itself. Not verified in practice.
- Does not modify save data, game files or archives. Removing the folder removes the mod.

## Status

This is version 0.1.0 and it has not been run in the game yet: it was written on a machine
that cannot launch Cyberpunk 2077. Everything it does was verified statically against the
game's decompiled scripts, and every uncertain call has a fallback and a log entry, but
expect rough edges on the first run.

Three things in particular are unverified and may need adjusting:
finding loot around the player (three strategies are implemented, the one that works is
picked automatically and named in the settings window), whether the prompt updates cleanly
when the count changes, and whether the native hold animation lines up with the configured
hold time. If something misbehaves, the log will say which of these it was.

## License

MIT — see [LICENSE](LICENSE).
