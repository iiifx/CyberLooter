-- Finding lootable objects around the player.
--
-- There is no single API that returns everything lootable nearby, so three
-- sources run on every scan and their results are merged and deduplicated.
-- None of them is complete on its own - most importantly, the general targeting
-- query stops returning enemies as soon as they die, which is exactly when their
-- bodies become worth looting.
--
-- A fourth source (the mappin system) was implemented and removed: on game 2.x it
-- hands back records with no entity handle. See docs/RESEARCH.md section 9.

local Scanner = {}

local Log, Config, State

local CACHE_SECONDS = 0.3
local REGISTRY_TTL = 60.0
local REGISTRY_PRUNE_INTERVAL = 30.0

local _time = 0.0
local _cacheStamp = -1.0
local _cache = { objects = {}, stacks = 0 }
local _nextPrune = REGISTRY_PRUNE_INTERVAL

-- Source C keeps its own passive registry, filled by observers.
local _mappinRegistry = {}
local _registryCount = 0

-- Which sources contributed to the last scan, for the settings window and log.
Scanner.strategy = "no scan yet"

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

-- An entity found in the world is rarely the thing that owns the items. An item
-- lying on a table or the floor is a visual ItemObject; the inventory lives on
-- the item drop it is connected to (item.swift:20-22):
--     public final native const func IsConnectedWithDrop() -> Bool;
--     public final native const func GetConnectedItemDrop() -> wref<gameItemDropObject>;
-- Using only GetOwner() here is what made loose world items unlootable.
local function resolveHolder(obj)
    if obj == nil then
        return nil
    end

    if isItemObject(obj) then
        local dropOk, drop = pcall(function()
            return obj:GetConnectedItemDrop()
        end)
        if dropOk and drop ~= nil then
            return drop
        end

        local ownerOk, owner = pcall(obj.GetOwner, obj)
        if ownerOk and owner ~= nil and isA(owner, CLASS_ITEM_DROP) then
            return owner
        end
    end

    return obj
end

-- Some items must never be moved into the inventory, because the game does not
-- put them there itself. Heavy weapons - the mounted machine guns and miniguns
-- you carry in your hands - live in the WeaponHeavy equip area and are meant to
-- be picked up through the interaction that equips them. Transferring one as if
-- it were loot leaves the player in the carrying pose holding nothing at all.
function Scanner.IsRestrictedItem(itemData)
    local ok, restricted = pcall(function()
        local itemType = itemData:GetItemType()
        if Equals(itemType, gamedataItemType.Wea_HeavyMachineGun)
            or Equals(itemType, gamedataItemType.Wea_LightMachineGun) then
            return true
        end

        -- Weapons discarded when empty are the same kind of hand-carried pickup.
        if itemData:HasTag("DiscardOnEmpty") then
            return true
        end

        local record = RPGManager.GetItemRecord(ItemID.GetTDBID(itemData:GetID()))
        if record ~= nil then
            local area = record:EquipArea()
            if area ~= nil and Equals(area:Type(), gamedataEquipmentArea.WeaponHeavy) then
                return true
            end
        end

        return false
    end)

    -- If the question cannot be answered, leave the item alone rather than risk
    -- repeating the broken-state bug.
    if not ok then
        Log.DebugThrottled("scan.restricted", 30, "restricted check failed: " .. tostring(restricted))
        return true
    end

    return restricted == true
end

-- Counts stacks rather than units: 45 rounds of ammo is one entry, which keeps
-- the number on the indicator readable. Restricted items are counted separately
-- and never contribute to what the mod offers to take.
local function inspect(holder)
    local ok, list = pcall(function()
        local _, items = Game.GetTransactionSystem():GetItemList(holder)
        return items
    end)

    if not ok or list == nil then
        return 0, 0
    end

    local lootable = 0
    local restricted = 0

    for _, itemData in ipairs(list) do
        if Scanner.IsRestrictedItem(itemData) then
            restricted = restricted + 1
        else
            lootable = lootable + 1
        end
    end

    return lootable, restricted
end

local function isLootCandidate(obj)
    if obj == nil then
        return false
    end

    -- Never the player, never anything they are driving.
    if isA(obj, "PlayerPuppet") or isA(obj, "vehicleBaseObject") then
        return false
    end

    -- Creatures: corpses only. A living NPC must never be emptied.
    if isA(obj, "ScriptedPuppet") then
        local ok, dead = pcall(function()
            return obj:IsDead() or ScriptedPuppet.IsDefeated(obj)
        end)
        return ok and dead == true
    end

    -- Known loot classes. gameLootContainerBase covers gameContainerObjectBase and,
    -- through it, gameContainerObjectSingleItem; gameLootBag derives straight from
    -- gameObject and needs its own check.
    if isA(obj, CLASS_ITEM_DROP)
        or isA(obj, "gameLootBag")
        or isA(obj, "gameLootContainerBase") then
        return true
    end

    -- Everything else is judged by whether it actually holds items the mod is
    -- allowed to take. A class whitelist turned out to be the wrong instinct:
    -- items on tables, shelves and inside furniture arrive as classes not worth
    -- enumerating, and were being discarded in silence. The inventory is the
    -- honest test.
    local lootable = inspect(obj)
    return lootable > 0
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
-- Source A: general targeting system spatial query
--------------------------------------------------------------------------------

local function sourceTargeting(player, radius)
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
        Log.DebugThrottled("scan.targeting", 30, "targeting source failed: " .. tostring(entities))
        return nil
    end

    return entities
end

--------------------------------------------------------------------------------
-- Source B: targeting query aimed specifically at bodies
--------------------------------------------------------------------------------

-- TSFMV is a bitfield: the mask bit is 1 << enum value.
--   Obj_Puppet = 1  -> 2
--   St_Dead = 11    -> 2048
--   St_Defeated = 13 -> 8192
--   St_Unconscious = 15 -> 32768
local MASK_PUPPET = 2
local MASK_NOT_ALIVE = 2048 + 8192 + 32768

-- The general query drops enemies the moment they die, which left corpses from a
-- just-finished fight unreachable until a reload. This one asks for exactly the
-- states the general one loses.
local function sourceTargetingDead(player, radius)
    local ok, entities = pcall(function()
        local query = gameTargetSearchQuery.new()
        query.maxDistance = radius
        query.filterObjectByDistance = true
        query.includeSecondaryTargets = false
        query.ignoreInstigator = true
        query.testedSet = gameTargetingSet.Complete
        query.searchFilter = TSF_And(TSF_All(MASK_PUPPET), TSF_Any(MASK_NOT_ALIVE))

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
        Log.DebugThrottled("scan.corpses", 30, "corpse source failed: " .. tostring(entities))
        return nil
    end

    return entities
end

--------------------------------------------------------------------------------
-- Source C: passive registry fed by loot marker controllers
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

local function sourceRegistry(player, radius)
    local found = {}
    local stale = {}

    for key, entry in pairs(_mappinRegistry) do
        -- Entries nothing has refreshed for a while are gone, looted, or far behind us.
        if (_time - entry.stamp) > REGISTRY_TTL then
            stale[#stale + 1] = key
        else
            -- Stored ids can outlive their entities (save reload, streaming), so
            -- the lookup is protected like the other two strategies are.
            local ok, entity = pcall(Game.FindEntityByID, entry.id)
            if ok and entity ~= nil then
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

local SOURCES = {
    { name = "targeting", run = sourceTargeting },
    { name = "corpses", run = sourceTargetingDead },
    { name = "registry", run = sourceRegistry },
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
    local rejected = {}

    for _, entity in ipairs(entities) do
        local holder = resolveHolder(entity)

        -- With the debug log on, note what was discarded and under which class.
        -- If something lootable is ever missed again, this names it directly
        -- instead of leaving us guessing.
        if Log.IsEnabled() and holder ~= nil and not isLootCandidate(holder) then
            local nameOk, className = pcall(function()
                return tostring(holder:GetClassName().value)
            end)
            local key = (nameOk and className) or "unknown"
            rejected[key] = (rejected[key] or 0) + 1
        end

        if holder ~= nil and isLootCandidate(holder) then
            local key = entityKey(holder)

            if key ~= nil and not seen[key] then
                seen[key] = true

                local dist = distanceTo(playerPos, holder)
                if dist ~= nil and dist <= radius then
                    local count, restricted = inspect(holder)

                    if count > 0 then
                        if Config.values.skipQuestItems and hasQuestLoot(holder) then
                            skippedQuest = skippedQuest + 1
                        else
                            objects[#objects + 1] = {
                                holder = holder,
                                distance = dist,
                                stacks = count,
                                -- Mixed contents: the bulk transfer would take the
                                -- restricted item too, so this one goes item by item.
                                restricted = restricted > 0,
                            }
                            stacks = stacks + count
                        end
                    elseif restricted > 0 then
                        Log.DebugThrottled("scan.restrictedonly", 10.0,
                            "skipping object holding only hand-carried items")
                    end
                end
            end
        end
    end

    table.sort(objects, function(a, b)
        return a.distance < b.distance
    end)

    if Log.IsEnabled() and next(rejected) ~= nil then
        local parts = {}
        for className, count in pairs(rejected) do
            parts[#parts + 1] = className .. "=" .. tostring(count)
        end
        Log.DebugThrottled("scan.rejected", 5.0, "not lootable: " .. table.concat(parts, " "))
    end

    return objects, stacks, skippedQuest
end

-- Cached: called both by the indicator every frame and by the sweep.
--
-- Every source runs on every scan and the results are merged. An earlier version
-- locked onto the first source that worked and switched the others off, which
-- broke on freshly killed enemies: the engine drops dead NPCs from the targeting
-- system, so corpses from a just-finished fight were invisible until a save and
-- reload brought them back as already-dead entities. No single source sees
-- everything, so the union is what counts.
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
    local merged = {}
    local detail = {}
    local contributors = {}

    for _, source in ipairs(SOURCES) do
        local entities = source.run(player, radius)
        local count = entities and #entities or 0

        detail[#detail + 1] = source.name .. "=" .. tostring(count)

        if count > 0 then
            contributors[#contributors + 1] = source.name
            for _, entity in ipairs(entities) do
                merged[#merged + 1] = entity
            end
        end
    end

    -- collect() deduplicates, so overlap between sources is free.
    local objects, stacks, skippedQuest = collect(merged, player, radius)

    Scanner.strategy = #contributors > 0 and table.concat(contributors, "+") or "nothing found"

    Log.DebugThrottled("scan.result", 2.0, string.format(
        "scan [%s]: %d raw, %d lootable, %d stacks, %d quest skipped",
        table.concat(detail, " "), #merged, #objects, stacks, skippedQuest))

    _cache = { objects = objects, stacks = stacks }
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
