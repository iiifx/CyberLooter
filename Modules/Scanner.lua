-- Finding lootable objects around the player.
--
-- This is the one piece the research could not settle statically, so three
-- independent strategies are implemented and tried in order. The first one that
-- yields actual lootable objects (not merely raw entities) is locked in for the
-- session and reported in the log; until then every strategy is retried.

local Scanner = {}

local Log, Config, State

local CACHE_SECONDS = 0.3
local REGISTRY_TTL = 60.0
local REGISTRY_PRUNE_INTERVAL = 30.0

local _time = 0.0
local _cacheStamp = -1.0
local _cache = { objects = {}, stacks = 0 }
local _nextPrune = REGISTRY_PRUNE_INTERVAL

-- Strategy C keeps its own passive registry, filled by observers.
local _mappinRegistry = {}
local _registryCount = 0

Scanner.strategy = "unresolved"
Scanner.strategyLocked = false

-- Native RTTI names. Script aliases such as "ItemObject" may or may not resolve
-- through IsA, so the native name is tried first and the alias only as a backstop.
local CLASS_ITEM_DROP = "gameItemDropObject"
local CLASS_ITEM_OBJECT = "gameItemObject"
local CLASS_ITEM_OBJECT_ALIAS = "ItemObject"

local function isA(obj, className)
    local ok, result = pcall(obj.IsA, obj, className)
    return ok and result == true
end

local function isItemObject(obj)
    return isA(obj, CLASS_ITEM_OBJECT) or isA(obj, CLASS_ITEM_OBJECT_ALIAS)
end

-- An entity found in the world is not always the thing that owns the items:
-- a dropped item is an ItemObject whose owner is the gameItemDropObject holding
-- the inventory. Mirrors what the loot marker code has to do.
local function resolveHolder(obj)
    if obj == nil then
        return nil
    end

    if isItemObject(obj) then
        local ok, owner = pcall(obj.GetOwner, obj)
        if ok and owner ~= nil and isA(owner, CLASS_ITEM_DROP) then
            return owner
        end
    end

    return obj
end

local function isLootCandidate(obj)
    if obj == nil then
        return false
    end

    -- gameContainerObjectSingleItem derives from gameContainerObjectBase, so the
    -- base check already covers it; it is listed for clarity, not necessity.
    if isA(obj, CLASS_ITEM_DROP)
        or isA(obj, "gameLootBag")
        or isA(obj, "gameLootContainerBase")
        or isA(obj, "gameContainerObjectBase")
        or isA(obj, "gameContainerObjectSingleItem") then
        return true
    end

    -- Corpses: a living NPC must never be looted.
    if isA(obj, "ScriptedPuppet") then
        local ok, dead = pcall(function()
            return obj:IsDead() or ScriptedPuppet.IsDefeated(obj)
        end)
        return ok and dead == true
    end

    return false
end

-- Number of stacks, not units: 45 rounds of ammo count as one entry, which keeps
-- the number on the indicator readable.
local function countStacks(holder)
    local ok, list = pcall(function()
        local _, items = Game.GetTransactionSystem():GetItemList(holder)
        return items
    end)

    if not ok or list == nil then
        return 0
    end

    return #list
end

local function hasQuestLoot(holder)
    local ok, isQuest = pcall(function()
        return holder:IsQuest()
    end)

    if ok and isQuest == true then
        return true
    end

    -- Object-level flag is not available on every class, so also look at the items.
    local listOk, list = pcall(function()
        local _, items = Game.GetTransactionSystem():GetItemList(holder)
        return items
    end)

    if not listOk or list == nil then
        return false
    end

    for _, item in ipairs(list) do
        local tagOk, tagged = pcall(function()
            return item:HasTag("Quest")
        end)
        if tagOk and tagged == true then
            return true
        end
    end

    return false
end

local function distanceTo(playerPos, obj)
    local ok, dist = pcall(function()
        return Vector4.Distance(playerPos, obj:GetWorldPosition())
    end)

    if not ok then
        return nil
    end

    return dist
end

--------------------------------------------------------------------------------
-- Strategy A: targeting system spatial query
--------------------------------------------------------------------------------

local function strategyTargeting(player, radius)
    local ok, entities = pcall(function()
        local query = TSQ_ALL()
        query.maxDistance = radius
        query.filterObjectByDistance = true
        query.includeSecondaryTargets = false
        query.ignoreInstigator = true

        -- Complete = do not restrict by what is on screen or in front of the player.
        pcall(function()
            query.testedSet = gameTargetingSet.Complete
        end)

        local success, parts = Game.GetTargetingSystem():GetTargetParts(player, query)
        if not success or parts == nil then
            return nil
        end

        local found = {}
        for _, part in ipairs(parts) do
            local component = gametargetingTargetPartInfo.GetComponent(part)
            if component ~= nil then
                local entity = component:GetEntity()
                if entity ~= nil then
                    found[#found + 1] = entity
                end
            end
        end
        return found
    end)

    if not ok then
        Log.DebugThrottled("scan.targeting", 30, "strategy targeting failed: " .. tostring(entities))
        return nil
    end

    return entities
end

--------------------------------------------------------------------------------
-- Strategy B: mappin system
--------------------------------------------------------------------------------

-- Note: on game 2.x GetMappins is documented to return gamemappinsMappinEntry
-- records, which carry only id/type/worldPosition and no entity handle - there is
-- nothing to loot from those. Older builds returned IMappin objects that do expose
-- GetEntityID. Both shapes are handled, and the shape actually observed is logged
-- once so the strategy can be dropped for good if it never yields anything.
local function strategyMappins(player, radius)
    local ok, entities = pcall(function()
        local system = Game.GetMappinSystem()
        if system == nil then
            return nil
        end

        local mappins = system:GetMappins(gamemappinsMappinTargetType.World)
        if mappins == nil then
            return nil
        end

        local found = {}
        local usable = 0

        for _, mappin in ipairs(mappins) do
            local gotID, entityID = pcall(function()
                return mappin:GetEntityID()
            end)

            if gotID and entityID ~= nil then
                usable = usable + 1
                local entity = Game.FindEntityByID(entityID)
                if entity ~= nil then
                    found[#found + 1] = entity
                end
            end
        end

        Log.DebugThrottled("scan.mappins.shape", 30, string.format(
            "mappin system returned %d records, %d exposed an entity id",
            #mappins, usable))

        return found
    end)

    if not ok then
        Log.DebugThrottled("scan.mappins", 30, "strategy mappins failed: " .. tostring(entities))
        return nil
    end

    return entities
end

--------------------------------------------------------------------------------
-- Strategy C: passive registry fed by loot marker controllers
--------------------------------------------------------------------------------

-- Called from the observers registered in Scanner.InstallObservers.
local function rememberMappinController(ctrl)
    local ok, err = pcall(function()
        local mappin = ctrl:GetMappin()
        if mappin == nil then
            return
        end

        local variant = mappin:GetVariant()
        if variant ~= gamedataMappinVariant.LootVariant then
            return
        end

        local entityID = mappin:GetEntityID()
        if entityID == nil then
            return
        end

        local key = tostring(entityID.hash)
        if _mappinRegistry[key] == nil then
            _registryCount = _registryCount + 1
        end
        _mappinRegistry[key] = { id = entityID, stamp = _time }
    end)

    if not ok then
        Log.DebugThrottled("scan.registry.observe", 30, "mappin observer failed: " .. tostring(err))
    end
end

-- The observers keep feeding the registry for the whole session regardless of
-- which strategy ended up being used, so pruning has to run on its own schedule
-- rather than inside the strategy - otherwise the table grows without bound.
local function pruneRegistry()
    local stale = {}

    for key, entry in pairs(_mappinRegistry) do
        if (_time - entry.stamp) > REGISTRY_TTL then
            stale[#stale + 1] = key
        end
    end

    for _, key in ipairs(stale) do
        _mappinRegistry[key] = nil
        _registryCount = _registryCount - 1
    end

    if #stale > 0 then
        Log.DebugThrottled("scan.registry.prune", 60, string.format(
            "registry pruned: %d dropped, %d kept", #stale, _registryCount))
    end
end

local function strategyRegistry(player, radius)
    local found = {}
    local stale = {}

    for key, entry in pairs(_mappinRegistry) do
        -- Entries nothing has refreshed for a while are gone, looted, or far behind us.
        if (_time - entry.stamp) > REGISTRY_TTL then
            stale[#stale + 1] = key
        else
            local entity = Game.FindEntityByID(entry.id)
            if entity ~= nil then
                found[#found + 1] = entity
            else
                stale[#stale + 1] = key
            end
        end
    end

    for _, key in ipairs(stale) do
        _mappinRegistry[key] = nil
        _registryCount = _registryCount - 1
    end

    return found
end

function Scanner.InstallObservers()
    local ok, err = pcall(function()
        ObserveAfter("GameplayMappinController", "UpdateVisibility", function(ctrl)
            rememberMappinController(ctrl)
        end)

        ObserveAfter("GameplayMappinController", "UpdateIcon", function(ctrl)
            rememberMappinController(ctrl)
        end)
    end)

    if not ok then
        Log.Warn("could not install mappin observers (strategy C unavailable): " .. tostring(err))
    end
end

--------------------------------------------------------------------------------

local STRATEGIES = {
    { name = "targeting", run = strategyTargeting },
    { name = "mappins", run = strategyMappins },
    { name = "registry", run = strategyRegistry },
}

function Scanner.Init(deps)
    Log = deps.Log
    Config = deps.Config
    State = deps.State
end

function Scanner.Tick(dt)
    _time = _time + dt

    if _time >= _nextPrune then
        _nextPrune = _time + REGISTRY_PRUNE_INTERVAL
        pruneRegistry()
    end
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

-- Turns raw entities into the deduplicated, filtered, in-range result set.
-- Entities can go stale between the world query and this loop, so every step
-- that touches a handle is allowed to fail without taking the scan down.
local function collect(entities, player, radius)
    local posOk, playerPos = pcall(function()
        return player:GetWorldPosition()
    end)

    if not posOk or playerPos == nil then
        Log.DebugThrottled("scan.playerpos", 30, "player position unavailable")
        return {}, 0, 0
    end

    local seen = {}
    local objects = {}
    local stacks = 0
    local skippedQuest = 0

    for _, entity in ipairs(entities) do
        local holder = resolveHolder(entity)

        if holder ~= nil and isLootCandidate(holder) then
            local key = entityKey(holder)

            if key ~= nil and not seen[key] then
                seen[key] = true

                local dist = distanceTo(playerPos, holder)
                if dist ~= nil and dist <= radius then
                    local count = countStacks(holder)

                    if count > 0 then
                        if Config.values.skipQuestItems and hasQuestLoot(holder) then
                            skippedQuest = skippedQuest + 1
                        else
                            objects[#objects + 1] = {
                                holder = holder,
                                distance = dist,
                                stacks = count,
                            }
                            stacks = stacks + count
                        end
                    end
                end
            end
        end
    end

    table.sort(objects, function(a, b)
        return a.distance < b.distance
    end)

    return objects, stacks, skippedQuest
end

-- Cached: called both by the indicator every frame and by the sweep.
function Scanner.Get()
    if _cacheStamp >= 0 and (_time - _cacheStamp) < CACHE_SECONDS then
        return _cache.objects, _cache.stacks
    end

    _cacheStamp = _time

    local player = State.GetPlayer()
    if player == nil then
        _cache = { objects = {}, stacks = 0 }
        return _cache.objects, _cache.stacks
    end

    local radius = Config.values.radius

    for _, strategy in ipairs(STRATEGIES) do
                -- Once a strategy has proven itself, stop paying for the others.
        if not Scanner.strategyLocked or Scanner.strategy == strategy.name then
            local entities = strategy.run(player, radius)

            if entities ~= nil and #entities > 0 then
                local objects, stacks, skippedQuest = collect(entities, player, radius)

                if #objects > 0 then
                    if not Scanner.strategyLocked then
                        Scanner.strategy = strategy.name
                        Scanner.strategyLocked = true
                        Log.Info("scan strategy resolved: " .. strategy.name)
                    end

                    Log.DebugThrottled("scan.result", 2.0, string.format(
                        "scan via %s: %d raw, %d lootable, %d stacks, %d quest skipped",
                        strategy.name, #entities, #objects, stacks, skippedQuest))

                    _cache = { objects = objects, stacks = stacks }
                    return _cache.objects, _cache.stacks
                end

                Log.DebugThrottled("scan.empty." .. strategy.name, 10.0, string.format(
                    "strategy %s returned %d entities but none lootable (%d quest skipped)",
                    strategy.name, #entities, skippedQuest))
            end
        end
    end

    _cache = { objects = {}, stacks = 0 }
    return _cache.objects, _cache.stacks
end

-- Forces the next Get() to hit the world again; used right after a sweep.
function Scanner.Invalidate()
    _cacheStamp = -1.0
end

function Scanner.GetRegistrySize()
    return _registryCount
end

return Scanner
