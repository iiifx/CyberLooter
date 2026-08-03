-- The on-screen indicator, drawn by the engine rather than by us.
--
-- The game's own button prompts go through InputHintData + UpdateInputHintEvent
-- (defaultTransition.swift:1709). CET exposes a direct helper for it:
--     Game.SendInputHintData(show, data, targetHintContainer)
-- So the prompt appears in the vanilla place, in the vanilla style, with the
-- vanilla hold animation and the correct key glyph for keyboard or gamepad.

local Hint = {}

local Log, Config

local SOURCE = "CyberLooter"
local CONTAINER = "GameplayInputHelper"
local GAME_ACTION = "Choice1"

-- The engine can drop its hint container without telling us (save load, fast
-- travel, UI rebuild), which would leave the mod believing a prompt is on screen
-- that no longer exists. Re-sending periodically costs nothing and heals that.
local RESEND_INTERVAL = 3.0

local _visible = false
local _shownLabel = nil
local _shownAt = 0.0
local _time = 0.0
local _available = true

-- Runtime-only: a failure of the engine path must not silently rewrite the
-- user's saved preferences.
Hint.forcedFallback = false

local function buildData(label)
    local data = gameuiInputHintData.new()

    data.source = CName.new(SOURCE)
    data.action = CName.new(GAME_ACTION)
    data.localizedLabel = label
    data.holdIndicationType = inkInputHintHoldIndicationType.Hold
    data.enableHoldAnimation = true
    data.queuePriority = 0
    data.sortingPriority = 0

    return data
end

local function send(show, label)
    local ok, err = pcall(function()
        Game.SendInputHintData(show, buildData(label or ""), CONTAINER)
    end)

    if not ok then
        if _available then
            _available = false
            Hint.forcedFallback = true
            Log.Warn("native input hint unavailable, falling back to ImGui: " .. tostring(err))
        end
        return false
    end

    return true
end

function Hint.Init(deps)
    Log = deps.Log
    Config = deps.Config
end

function Hint.IsAvailable()
    return _available
end

-- `bind` is the key the player actually assigned in CET.
function Hint.Update(count, bind)
    if not Config.values.showIndicator or not _available or count <= 0 then
        Hint.Clear()
        return
    end

    -- The key glyph itself always comes from the game's interact action: the hint
    -- system renders it from `action`, and there is no way to ask for a prompt
    -- without one. When the mod is bound to some other key, hintShowKeyName adds
    -- the real key name to the text so the prompt is not misleading.
    local label
    if Config.values.hintShowKeyName then
        label = string.format("%s [%s] · %d", Config.values.hintLabel, tostring(bind or "?"), count)
    else
        label = string.format("%s · %d", Config.values.hintLabel, count)
    end

    if _visible and _shownLabel == label and (_time - _shownAt) < RESEND_INTERVAL then
        return
    end

    -- Re-sending the same action+source is expected to update the existing hint.
    -- If it turns out to stack duplicates instead, this switch takes the hint
    -- down first and puts it back up.
    if _visible and Config.values.hintRefreshHack then
        send(false, _shownLabel)
    end

    if send(true, label) then
        _visible = true
        _shownLabel = label
        _shownAt = _time
        Log.DebugThrottled("hint.show", 5.0, "hint shown: " .. label)
    end
end

function Hint.Tick(dt)
    _time = _time + dt
end

function Hint.Clear()
    if not _visible then
        return
    end

    send(false, _shownLabel)
    _visible = false
    _shownLabel = nil
    Log.DebugThrottled("hint.hide", 5.0, "hint cleared")
end

return Hint
