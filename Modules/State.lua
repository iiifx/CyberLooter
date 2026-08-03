-- Game state gates: when the mod must keep quiet.

local State = {}

local Log

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

-- True when the game itself has an interaction prompt up (door, corpse, ladder...).
-- Verified in player.swift:905 - a non-empty choices array means a live prompt.
function State.HasVanillaInteraction()
    local ok, result = pcall(function()
        local defs = GetAllBlackboardDefs().UIInteractions
        local bb = Game.GetBlackboardSystem():Get(defs)
        if bb == nil then
            return false
        end

        local hub = bb:GetVariant(defs.InteractionChoiceHub)
        if hub == nil or hub.choices == nil then
            return false
        end

        return #hub.choices > 0
    end)

    if not ok then
        Log.DebugThrottled("state.interaction", 30,
            "InteractionChoiceHub check failed: " .. tostring(result))
        return false
    end

    return result and true or false
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
