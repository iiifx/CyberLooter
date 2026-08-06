-- CyberLooter - accessibility mod for Cyberpunk 2077.
-- Hold one key to loot everything within a radius around the player.
-- Requires Cyber Engine Tweaks. No other dependencies.
--
-- Note on structure: CET clears registerForEvent / registerInput as soon as
-- init.lua finishes executing (ScriptContext.cpp:195), so every registration
-- has to happen while this file is being run - not later from onInit.

local Log = require("Modules/Log.lua")
local Config = require("Modules/Config.lua")
local State = require("Modules/State.lua")
local Scanner = require("Modules/Scanner.lua")
local Looter = require("Modules/Looter.lua")
local Hint = require("Modules/Hint.lua")
local Hud = require("Modules/Hud.lua")
local Input = require("Modules/Input.lua")
local Auto = require("Modules/Auto.lua")
local Audit = require("Modules/Audit.lua")

local CyberLooter = {
    version = "0.4.4",
    ready = false,
}

local _lastStacks = 0
local _time = 0.0

-- A mod that has silently stopped scanning looks exactly like a world with no
-- loot in it, which is what made the last outage so hard to place. Whenever the
-- indicator is suppressed for long enough to be noticed, the reason goes into the
-- log at INFO level - visible without turning the debug switch on - and so does
-- the moment it starts working again.
local SUPPRESSION_REPORT_AFTER = 10.0
local _suppressedSince = nil
local _suppressionReported = false

local function loadVersion()
    local file = io.open("version.txt", "r")
    if file == nil then
        return CyberLooter.version
    end

    local version = file:read("*l")
    file:close()

    if version == nil or version == "" then
        return CyberLooter.version
    end

    return version
end

local function onSweep()
    Looter.Sweep()
end

local function suppress(reason)
    Hint.Clear()

    if _suppressedSince == nil then
        _suppressedSince = _time
        _suppressionReported = false
    elseif not _suppressionReported and (_time - _suppressedSince) >= SUPPRESSION_REPORT_AFTER then
        _suppressionReported = true
        Log.Info(string.format("scanning has been suppressed for %.0fs, reason: %s",
            _time - _suppressedSince, tostring(reason)))
    end

    return 0
end

local function resume()
    if _suppressedSince == nil then
        return
    end

    if _suppressionReported then
        Log.Info(string.format("scanning resumed after %.0fs", _time - _suppressedSince))
    end

    _suppressedSince = nil
    _suppressionReported = false
end

-- Keeps the indicator honest: it is only shown when a sweep would actually run.
local function updateIndicator()
    -- A prompt that says "hold to loot" while the mod is already looting on its
    -- own would be both wrong and, at two sweeps a second, a flicker.
    if Config.values.autoLoot then
        Hint.Clear()
        resume()
        return 0
    end

    -- Deliberately not counted as suppression: the sweep runs regardless of
    -- whether the prompt is drawn, so there is nothing to report.
    if not Config.values.showIndicator then
        Hint.Clear()
        resume()
        return 0
    end

    -- Without a binding the prompt would advertise an action the player has no
    -- way to trigger.
    if not Input.IsBound() then
        return suppress("no key bound")
    end

    local actionable, reason = State.IsActionable(Config.values.respectInteraction)
    if not actionable then
        return suppress(reason)
    end

    resume()

    local _, stacks = Scanner.Get()
    Hint.Update(stacks, Input.GetBind())

    return stacks
end

local function main()
    local deps = {
        Log = Log,
        Config = Config,
        State = State,
        Scanner = Scanner,
        Looter = Looter,
        Hint = Hint,
        Hud = Hud,
        Auto = Auto,
        Audit = Audit,
        onSweep = onSweep,
    }

    -- Load-time wiring: config file, overlay events and the key binding.
    Config.Init(deps)
    State.Init(deps)
    Scanner.Init(deps)
    Looter.Init(deps)
    Hint.Init(deps)
    Hud.Init(deps)
    Input.Init(deps)
    Auto.Init(deps)
    Audit.Init(deps)

    registerForEvent("onInit", function()
        -- Observers need the game's script classes, which only exist by now.
        Scanner.InstallObservers()

        CyberLooter.version = loadVersion()
        CyberLooter.ready = true

        Log.Info("loaded v" .. CyberLooter.version)
        if not Input.IsBound() then
            Log.Info("no key bound yet - assign one in CET > Bindings > CyberLooter")
        end
    end)

    registerForEvent("onUpdate", function(dt)
        if not CyberLooter.ready then
            return
        end

        _time = _time + dt

        State.Tick(dt)
        Scanner.Tick(dt)
        Hint.Tick(dt)
        Input.Tick(dt)
        Auto.Tick(dt)

        _lastStacks = updateIndicator()
    end)

    registerForEvent("onDraw", function()
        if not CyberLooter.ready then
            return
        end

        if Config.isOverlayOpen then
            -- Scanned live rather than reusing the indicator's number, which is
            -- zero whenever the indicator is suppressed.
            local objects, stacks = Scanner.Get()
            Config.DrawWindow({
                bound = Input.IsBound(),
                bind = Input.GetBind() or "-",
                strategy = Scanner.strategy,
                objects = #objects,
                stacks = stacks,
                lastSweep = Looter.lastSweep,
                registrySize = Scanner.GetRegistrySize(),
                hintForcedFallback = Hint.forcedFallback,
                interactionGuardBroken = State.interactionCheckBroken,
                heavyFilterBroken = Scanner.restrictedCheckAnswered == false,
                autoReason = Auto.lastReason,
                skip = Scanner.lastSkip,
                onDumpInventory = Audit.DumpInventory,
                onFindStuck = Audit.FindStuckItems,
                onRemoveStuck = Audit.RemoveStuckItems,
            })
        end

        -- Fallback path only, and never worth breaking the frame over.
        local ok, err = pcall(Hud.Draw, _lastStacks, Input.GetProgress(), Input.GetBind())
        if not ok then
            Log.DebugThrottled("hud.draw", 30, "ImGui indicator failed: " .. tostring(err))
        end
    end)

    registerForEvent("onShutdown", function()
        -- Leaving a hint on screen after unload would be a visible artefact.
        Hint.Clear()
        Config.SaveIfDirty()
    end)
end

main()

return CyberLooter
