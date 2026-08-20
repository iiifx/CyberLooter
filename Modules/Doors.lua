-- Opening the door you are looking at, so the interact key is not needed for it.
--
-- The action sent is the same one the vanilla prompt runs. Pressing F on a door
-- executes the ToggleOpen device action (doorController.swift:675 builds it,
-- :703 handles it), and the game queues that action exactly like this when it
-- opens a door on its own behalf (doorController.swift:1341):
--     action = ps.ActionToggleOpen();
--     action.SetExecutor(executor);
--     action.RegisterAsRequester(...);
--     GetPersistencySystem().QueuePSDeviceEvent(action);
--
-- Deliberately not Door.OpenDoor(): that goes through ActionSetOpened, which only
-- refuses sealed and disabled doors and would therefore open a locked one. This
-- mod does not pick locks - it saves a keypress on doors the player could already
-- walk through.

local Doors = {}

local Log, Config, State

-- The door under the cursor changes as the player turns, so the check has to be
-- frequent enough to feel immediate, and cheap enough to run at that rate: one
-- look-at query plus a handful of state reads on a single object.
local CHECK_INTERVAL = 0.2

-- Some doors close themselves again after a moment. Re-opening one on the next
-- check would fight the game, so a door that was just opened is left alone for a
-- while - long enough for the player to walk through or to turn away.
local REOPEN_COOLDOWN = 10.0
local MEMORY_PRUNE_INTERVAL = 30.0

local _time = 0.0
local _sinceCheck = 0.0
local _nextPrune = MEMORY_PRUNE_INTERVAL
local _openedAt = {}

-- Exposed for the settings window: why nothing is happening right now.
Doors.lastReason = "off"

-- Window and MovableWallScreen both extend Door (window.swift, movableWallScreen.swift)
-- and would otherwise be swept along by the class test. A blind that opens because
-- the player glanced at it is not the feature.
local DOOR_CLASS = "Door"
local NOT_A_DOOR_CLASSES = { "Window", "MovableWallScreen" }

-- EDoorType. AUTOMATIC doors open by themselves and never carry a prompt, so
-- toggling one is at best a no-op and at worst fights the trigger volume;
-- REMOTELY_CONTROLLED doors are driven by a terminal or a quest, and that is
-- someone else's decision to make.
local SKIPPED_DOOR_TYPES = { "AUTOMATIC", "REMOTELY_CONTROLLED" }

local function isA(obj, className)
    local ok, result = pcall(obj.IsA, obj, className)
    return ok and result == true
end

-- Returns true/false, or nil when the question could not be asked at all.
local function ask(key, fn)
    local ok, result = pcall(fn)

    if not ok then
        Log.DebugThrottled("doors.ask." .. key, 30.0,
            "door check '" .. key .. "' unavailable: " .. tostring(result))
        return nil
    end

    return result == true
end

local function entityKey(obj)
    local ok, key = pcall(function()
        return tostring(obj:GetEntityID().hash)
    end)

    if not ok then
        return nil
    end

    return key
end

local function prune()
    if _time < _nextPrune then
        return
    end

    _nextPrune = _time + MEMORY_PRUNE_INTERVAL

    for key, stamp in pairs(_openedAt) do
        if (_time - stamp) > REOPEN_COOLDOWN then
            _openedAt[key] = nil
        end
    end
end

-- The object the player is actually looking at, which is what puts the prompt on
-- screen in the first place. withLOS is on: a door behind a wall is not a door the
-- player is standing in front of.
local function lookAtObject(player)
    local ok, obj = pcall(function()
        return Game.GetTargetingSystem():GetLookAtObject(player, true, false)
    end)

    if not ok then
        Log.DebugThrottled("doors.lookat", 30.0, "look-at query failed: " .. tostring(obj))
        return nil
    end

    return obj
end

local function isDoor(obj)
    if obj == nil or not isA(obj, DOOR_CLASS) then
        return false
    end

    for _, className in ipairs(NOT_A_DOOR_CLASSES) do
        if isA(obj, className) then
            return false
        end
    end

    return true
end

local function withinReach(player, door)
    local ok, distance = pcall(function()
        return Vector4.Distance(player:GetWorldPosition(), door:GetWorldPosition())
    end)

    if not ok or distance == nil then
        return false, "distance unreadable"
    end

    if distance > Config.values.autoOpenDoorDistance then
        return false, string.format("door is %.1fm away", distance)
    end

    return true, nil
end

-- The game's own answer to "could the player just walk through this".
--
-- Door.EvaluateOffMeshLinks (door.swift:145) decides whether to let navigation
-- route through a door, and the condition it uses for "openable without effort" is
--     !IsLocked() && !IsDeviceSecured() && !HasAnySkillCheckActive() && IsON()
-- on a door that IsClosed() and is neither disabled, sealed nor unpowered. Same
-- questions, same order, so this feature can never offer more than the game does.
--
-- Which unreadable answers are fatal is not uniform, and the split is deliberate.
-- Closed, locked and sealed must be known: toggling an open door closes it, which
-- is the one destructive direction available here, and opening a locked or sealed
-- door is the one thing this feature promises never to do. The rest only decide
-- whether the action would have succeeded anyway - if they cannot be read, the
-- worst case is a queued action the game refuses, so they do not veto.
local function openable(door, ps)
    local required = {
        { "closed", true, function() return ps:IsClosed() end },
        { "locked", false, function() return ps:IsLocked() end },
        { "sealed", false, function() return ps:IsSealed() end },
    }

    for _, check in ipairs(required) do
        local answer = ask(check[1], check[3])
        if answer == nil then
            return false, check[1] .. " state unreadable"
        end
        if answer ~= check[2] then
            return false, "door is " .. (check[2] and "not " or "") .. check[1]
        end
    end

    local optional = {
        { "disabled", function() return ps:IsDisabled() end },
        { "unpowered", function() return ps:IsUnpowered() end },
        { "secured", function() return ps:IsDeviceSecured() end },
        { "lift", function() return ps:IsLiftDoor() end },
        { "skillcheck", function() return door:HasAnySkillCheckActive() end },
    }

    for _, check in ipairs(optional) do
        if ask(check[1], check[2]) == true then
            return false, "door is " .. check[1]
        end
    end

    -- IsON is the only optional signal whose blocking answer is `false`.
    if ask("on", function() return ps:IsON() end) == false then
        return false, "door is off"
    end

    local skippedType = ask("doortype", function()
        local doorType = ps:GetDoorType()
        if doorType == nil then
            return false
        end

        for _, name in ipairs(SKIPPED_DOOR_TYPES) do
            local ok, member = pcall(function()
                return EDoorType[name]
            end)

            if ok and member ~= nil then
                local same, equal = pcall(Equals, doorType, member)
                if (same and equal == true) or doorType == member then
                    return true
                end
            end
        end

        return false
    end)
    if skippedType == true then
        return false, "door opens on its own or is remotely controlled"
    end

    return true, nil
end

local function open(player, door, ps)
    local ok, err = pcall(function()
        local action = ps:ActionToggleOpen()
        if action == nil then
            error("no ToggleOpen action on this door")
        end

        action:SetExecutor(player)

        -- The game passes PersistentID.ExtractEntityID(ps.GetID()) here, which is
        -- the door's own entity id - taken straight off the entity instead, so this
        -- does not depend on PersistentID being reachable from Lua.
        action:RegisterAsRequester(door:GetEntityID())

        Game.GetPersistencySystem():QueuePSDeviceEvent(action)
    end)

    if not ok then
        Log.DebugThrottled("doors.open", 10.0, "could not open the door: " .. tostring(err))
        return false
    end

    return true
end

function Doors.Init(deps)
    Log = deps.Log
    Config = deps.Config
    State = deps.State
end

-- Returns true when a door was opened on this tick.
function Doors.Tick(dt)
    _time = _time + dt

    if not Config.values.autoOpenDoors then
        _sinceCheck = 0.0
        Doors.lastReason = "off"
        return false
    end

    prune()

    _sinceCheck = _sinceCheck + dt
    if _sinceCheck < CHECK_INTERVAL then
        return false
    end
    _sinceCheck = 0.0

    local player = State.GetPlayer()
    if player == nil then
        Doors.lastReason = "no player"
        return false
    end

    -- Deliberately not the vanilla-interaction gate. Looking at an openable door is
    -- what puts a prompt on screen, so respecting that gate would switch this off
    -- exactly when it is meant to act. There is no key here to get in the way of.
    local actionable, reason = State.IsActionable(false)
    if not actionable then
        Doors.lastReason = reason or "blocked"
        return false
    end

    if State.IsMounted() then
        Doors.lastReason = "in a vehicle"
        return false
    end

    if State.IsInCombat() then
        Doors.lastReason = "in combat"
        return false
    end

    local target = lookAtObject(player)
    if not isDoor(target) then
        Doors.lastReason = "not looking at a door"
        return false
    end

    local inReach, tooFar = withinReach(player, target)
    if not inReach then
        Doors.lastReason = tooFar or "out of reach"
        return false
    end

    local key = entityKey(target)
    if key ~= nil and _openedAt[key] ~= nil and (_time - _openedAt[key]) < REOPEN_COOLDOWN then
        Doors.lastReason = "already opened this door"
        return false
    end

    local psOk, ps = pcall(function()
        return target:GetDevicePS()
    end)

    if not psOk or ps == nil then
        Doors.lastReason = "door state unavailable"
        Log.DebugThrottled("doors.ps", 30.0, "GetDevicePS failed: " .. tostring(ps))
        return false
    end

    local allowed, why = openable(target, ps)
    if not allowed then
        Doors.lastReason = why or "door cannot be opened"
        return false
    end

    if not open(player, target, ps) then
        Doors.lastReason = "opening failed"
        return false
    end

    if key ~= nil then
        _openedAt[key] = _time
    end

    Doors.lastReason = "opened a door"
    Log.DebugThrottled("doors.opened", 2.0, "opened the door in front of the player")

    return true
end

return Doors
