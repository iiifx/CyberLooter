-- Automatic sweeps, for when holding a key is itself the problem.
--
-- Same sweep, same filters, same gates as the manual one - the only difference
-- is what starts it. It runs on a timer rather than on a key, and only when the
-- scan has actually found something, so an empty street costs one cached scan
-- every half second and nothing else.

local Auto = {}

local Log, Config, State, Scanner, Looter

-- A sweep that collects nothing when the scan said there was something means the
-- objects in range cannot be emptied - a stuck handle, a container the transfer
-- refuses. Retrying that twice a second forever would fill the log and burn
-- frames, so an unproductive sweep buys a few seconds of quiet.
local BACKOFF_SECONDS = 3.0
local MIN_INTERVAL = 0.1

local _sinceSweep = 0.0
local _backoff = 0.0

function Auto.Init(deps)
    Log = deps.Log
    Config = deps.Config
    State = deps.State
    Scanner = deps.Scanner
    Looter = deps.Looter
end

-- Exposed for the settings window: why nothing is happening right now.
Auto.lastReason = "off"

function Auto.Tick(dt)
    if not Config.values.autoLoot then
        _sinceSweep = 0.0
        _backoff = 0.0
        Auto.lastReason = "off"
        return false
    end

    if _backoff > 0.0 then
        _backoff = _backoff - dt
        Auto.lastReason = "backing off"
        return false
    end

    _sinceSweep = _sinceSweep + dt

    local interval = Config.values.autoLootInterval
    if type(interval) ~= "number" or interval < MIN_INTERVAL then
        interval = MIN_INTERVAL
    end

    if _sinceSweep < interval then
        return false
    end

    _sinceSweep = 0.0

    -- Deliberately not the vanilla-interaction gate. That gate exists so the mod
    -- never acts on top of the interact key, and there is no key here; keeping it
    -- would block automatic looting exactly when the player looks at loot, since
    -- looking at loot is what puts a prompt on screen.
    local actionable, reason = State.IsActionable(false)
    if not actionable then
        Auto.lastReason = reason or "blocked"
        return false
    end

    if not Config.values.autoLootInVehicle and State.IsMounted() then
        Auto.lastReason = "in a vehicle"
        return false
    end

    local objects = Scanner.Get()
    if #objects == 0 then
        Auto.lastReason = "nothing in radius"
        return false
    end

    local collected = Looter.Sweep()

    if collected == 0 then
        _backoff = BACKOFF_SECONDS
        Auto.lastReason = "sweep collected nothing, pausing"
        Log.DebugThrottled("auto.backoff", 10.0, string.format(
            "auto-loot found %d objects but collected none, pausing for %.0fs",
            #objects, BACKOFF_SECONDS))
        return false
    end

    Auto.lastReason = "collecting"
    return true
end

return Auto
