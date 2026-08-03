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

local CyberLooter = {
    version = "0.2.0",
    ready = false,
}

local _lastStacks = 0

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

-- Keeps the indicator honest: it is only shown when a sweep would actually run.
local function updateIndicator()
    if not Config.values.showIndicator then
        Hint.Clear()
        return 0
    end

    -- Without a binding the prompt would advertise an action the player has no
    -- way to trigger.
    if not Input.IsBound() then
        Hint.Clear()
        return 0
    end

    local actionable = State.IsActionable(Config.values.respectInteraction)
    if not actionable then
        Hint.Clear()
        return 0
    end

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

        Scanner.Tick(dt)
        Hint.Tick(dt)
        Input.Tick(dt)

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
