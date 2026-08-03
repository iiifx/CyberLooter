-- Hold-to-sweep key handling.
--
-- CET does not consume the key press (VKBindings.cpp:537 always returns 0), so
-- binding this to the interaction key is safe: the game still does its normal
-- thing. The State gate is what keeps us from acting on top of it.

local Input = {}

local Log, Config, State

local BIND_ID = "cyberlooter_sweep"
local BIND_LABEL = "CyberLooter: loot everything around"

local _isDown = false
local _heldFor = 0.0
local _fired = false
local _onSweep = nil
local _wasBound = false

Input.bindId = BIND_ID

function Input.Init(deps)
    Log = deps.Log
    Config = deps.Config
    State = deps.State
    _onSweep = deps.onSweep

    registerInput(BIND_ID, BIND_LABEL, function(isDown)
        _isDown = isDown and true or false
        _heldFor = 0.0
        _fired = false

        -- Proof in the log that key events are still arriving. Without it, a mod
        -- that has gone quiet is indistinguishable from a player who stopped
        -- pressing the key.
        Log.DebugThrottled("input.event", 5.0, "key " .. (_isDown and "down" or "up"))
    end)
end

-- The binding is only used to decide whether the prompt may be shown; the sweep
-- itself runs off the callback registered above, which CET keeps delivering
-- regardless of what this reports. So a negative answer after the key has once
-- been bound is treated as a glitch rather than as a reason to go silent - the
-- alternative is a mod that quietly stops working until the game is reloaded.
function Input.IsBound()
    local ok, bound = pcall(IsBound, BIND_ID)

    if ok and bound == true then
        _wasBound = true
        return true
    end

    if _wasBound then
        Log.DebugThrottled("input.bindlost", 30.0,
            "IsBound() reported no binding for an already bound key, keeping it")
        return true
    end

    return false
end

function Input.GetBind()
    local ok, bind = pcall(GetBind, BIND_ID)
    if not ok or bind == nil or bind == "" then
        return nil
    end
    return bind
end

-- 0..1 while the key is held, for the fallback indicator.
function Input.GetProgress()
    if not _isDown or Config.values.holdTime <= 0 then
        return 0.0
    end

    return math.min(1.0, _heldFor / Config.values.holdTime)
end

function Input.IsHolding()
    return _isDown
end

function Input.Tick(dt)
    if not _isDown or _fired then
        return
    end

    _heldFor = _heldFor + dt

    if _heldFor < Config.values.holdTime then
        return
    end

    -- The gate is checked before the hold is consumed. If the player is holding
    -- the key while a vanilla prompt is up, the hold stays live and fires the
    -- moment the gate opens, instead of being burned and needing a fresh press.
    local actionable, reason = State.IsActionable(Config.values.respectInteraction)
    if not actionable then
        Log.DebugThrottled("input.blocked", 5.0, "hold on standby: " .. tostring(reason))
        return
    end

    -- One sweep per hold: the key can be released immediately afterwards.
    _fired = true

    if _onSweep ~= nil then
        local ok, err = pcall(_onSweep)
        if not ok then
            Log.Error("sweep failed: " .. tostring(err))
        end
    end
end

return Input
