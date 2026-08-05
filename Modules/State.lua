-- Game state gates: when the mod must keep quiet.

local State = {}

local Log
local _recoveryLogged = false

-- The interaction blackboard is not always cleared when a prompt goes away: a hub
-- can be left behind with its choices still in it, and since that gate is what
-- keeps the mod off the interact key, a leaked hub disables the mod for the rest
-- of the session. So an unchanged hub that has been "up" for this long is treated
-- as stale rather than believed indefinitely. A prompt the player is genuinely
-- standing in front of only loses the guard after the same delay, and the worst
-- that costs is one extra sweep alongside a normal interaction.
local HUB_STALE_AFTER = 20.0

local _time = 0.0
local _hubSignature = nil
local _hubSince = 0.0
local _staleLogged = false

function State.Tick(dt)
    _time = _time + dt
end

-- Set when the vanilla-interaction guard cannot read its blackboard, so the
-- settings window can admit that the guard is not actually running.
State.interactionCheckBroken = false

function State.Init(deps)
    Log = deps.Log
end

function State.GetPlayer()
    local ok, player = pcall(Game.GetPlayer)
    if not ok or player == nil then
        return nil
    end
    return player
end

-- True while any fullscreen menu / inventory / map is up.
function State.IsInMenu()
    local ok, result = pcall(function()
        local bb = Game.GetBlackboardSystem():Get(GetAllBlackboardDefs().UI_System)
        if bb == nil then
            return false
        end
        return bb:GetBool(GetAllBlackboardDefs().UI_System.IsInMenu)
    end)

    if not ok then
        Log.DebugThrottled("state.menu", 30, "IsInMenu check failed: " .. tostring(result))
        return false
    end

    return result and true or false
end

function State.IsPhotoModeActive()
    local ok, result = pcall(function()
        local system = Game.GetPhotoModeSystem()
        if system == nil then
            return false
        end
        return system:IsPhotoModeActive()
    end)

    return ok and result == true
end

-- True while the player is in a vehicle. Same source the game uses:
-- VehicleSystem.IsPlayerInVehicle (vehicleSystem.script:43) reads this exact
-- blackboard field rather than looking for a vehicle entity.
function State.IsMounted()
    local ok, result = pcall(function()
        local player = State.GetPlayer()
        if player == nil then
            return false
        end

        local bb = player:GetPlayerStateMachineBlackboard()
        if bb == nil then
            return false
        end

        return bb:GetBool(GetAllBlackboardDefs().PlayerStateMachine.MountedToVehicle)
    end)

    if not ok then
        Log.DebugThrottled("state.mounted", 30, "vehicle check failed: " .. tostring(result))
        return false
    end

    return result == true
end

-- True when the game itself has an interaction prompt up (door, corpse, ladder...).
-- Verified in player.swift:905 - a non-empty choices array means a live prompt.
--
-- The blackboard hands back a Variant (opaque userdata), so it has to be unpacked
-- with FromVariant before the struct fields exist. Older CET builds unpack it on
-- the way out, hence both shapes are accepted.
-- Enough of the hub to tell "still the same prompt" from "a new one", without
-- assuming any particular field exists on the running build.
local function hubSignature(hub)
    local parts = {}

    for _, field in ipairs({ "id", "title", "hubPriority" }) do
        local ok, value = pcall(function()
            return hub[field]
        end)
        parts[#parts + 1] = (ok and value ~= nil) and tostring(value) or "?"
    end

    local countOk, count = pcall(function()
        return #hub.choices
    end)
    parts[#parts + 1] = countOk and tostring(count) or "?"

    return table.concat(parts, "/")
end

function State.HasVanillaInteraction()
    local liveHub = nil

    local ok, result = pcall(function()
        local defs = GetAllBlackboardDefs().UIInteractions
        local bb = Game.GetBlackboardSystem():Get(defs)
        if bb == nil then
            return nil
        end

        local raw = bb:GetVariant(defs.InteractionChoiceHub)
        if raw == nil then
            return false
        end

        -- Unpack first. Touching a field on a raw Variant may throw rather than
        -- return nil, so it must never be the first thing tried.
        local hub = nil
        if FromVariant ~= nil then
            local unpacked, value = pcall(FromVariant, raw)
            if unpacked and value ~= nil then
                hub = value
            end
        end

        -- Older CET builds hand back an already-unpacked struct.
        if hub == nil then
            hub = raw
        end

        local readable, choices = pcall(function()
            return hub.choices
        end)

        if not readable then
            return nil
        end

        -- An empty or choice-less hub simply means no prompt is up, which is a
        -- perfectly normal state and must not be mistaken for a broken read.
        if choices == nil then
            return false
        end

        if #choices == 0 then
            return false
        end

        -- The hub carries its own liveness flag on builds that have it; a hub
        -- explicitly marked inactive is leftover data, not a prompt on screen.
        local activeOk, active = pcall(function()
            return hub.active
        end)
        if activeOk and active == false then
            return false
        end

        liveHub = hub
        return true
    end)

    -- nil means the read itself did not work, which is different from "no prompt".
    -- The mod stays usable (failing closed would disable it outright), but the
    -- broken state is surfaced loudly instead of hiding in a disabled debug log.
    if not ok or result == nil then
        if not State.interactionCheckBroken then
            State.interactionCheckBroken = true
            Log.Warn("cannot read InteractionChoiceHub - the 'ignore key during vanilla prompts' "
                .. "guard is inactive: " .. tostring(result))
        end
        return false
    end

    if State.interactionCheckBroken then
        State.interactionCheckBroken = false
        -- Logged at most once per session so a flapping read cannot spam the file.
        if not _recoveryLogged then
            _recoveryLogged = true
            Log.Info("InteractionChoiceHub became readable, vanilla prompt guard is active again")
        end
    end

    if result ~= true then
        _hubSignature = nil
        _staleLogged = false
        return false
    end

    -- A prompt is reported. Is it the same one as a moment ago, and for how long?
    local signature = liveHub ~= nil and hubSignature(liveHub) or "unreadable"

    if signature ~= _hubSignature then
        _hubSignature = signature
        _hubSince = _time
        _staleLogged = false
        return true
    end

    if (_time - _hubSince) >= HUB_STALE_AFTER then
        if not _staleLogged then
            _staleLogged = true
            Log.Warn(string.format(
                "the same interaction prompt has been reported for %.0fs (%s); treating it as "
                .. "leftover blackboard data so the mod does not stay disabled",
                _time - _hubSince, signature))
        end
        return false
    end

    return true
end

-- Single gate used by both the sweep and the indicator, so the hint never
-- promises something the sweep would refuse to do.
function State.IsActionable(respectInteraction)
    local player = State.GetPlayer()
    if player == nil then
        return false, "no player"
    end

    if State.IsInMenu() then
        return false, "menu"
    end

    if State.IsPhotoModeActive() then
        return false, "photo mode"
    end

    if respectInteraction and State.HasVanillaInteraction() then
        return false, "vanilla interaction"
    end

    return true, nil
end

return State
