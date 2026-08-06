-- Inventory dump and cleanup.
--
-- The backpack UI is a view, not the inventory: an item the interface has no
-- place for is simply not drawn, while its weight still counts against the carry
-- limit. That is not a hypothetical - one session ended with 14 vehicle-mounted
-- weapons and 2 heavy machine guns in the player's inventory, 183 kg of a 200 kg
-- limit, none of them visible and none of them droppable.
--
-- So this asks the transaction system instead, which is the same source the mod
-- loots through, and can put back what should never have been taken.

local Audit = {}

local Log, State, Scanner

function Audit.Init(deps)
    Log = deps.Log
    State = deps.State
    Scanner = deps.Scanner
end

local function nameOf(itemData)
    local path = Scanner.ItemPath(itemData)
    if path ~= nil then
        return path
    end

    local ok, fallback = pcall(function()
        return tostring(itemData:GetID().id)
    end)

    return (ok and fallback) or "?"
end

-- Weight has moved around between game versions, so every known way of asking is
-- tried and the first answer wins. An unknown weight is reported as unknown
-- rather than as zero, because zero is exactly the claim under suspicion.
local function weightOf(itemData)
    local viaManager, weight = pcall(function()
        return RPGManager.GetItemWeight(itemData)
    end)
    if viaManager and type(weight) == "number" then
        return weight
    end

    local viaStat, stat = pcall(function()
        return itemData:GetStatValueCurrent(gamedataStatType.Weight)
    end)
    if viaStat and type(stat) == "number" then
        return stat
    end

    return nil
end

-- Everything the record will say about what kind of thing this is. The point is
-- not to use it in a decision today but to find a decision worth making: an item
-- the backpack refuses to draw is classified as something, somewhere, and the
-- tags are the likeliest place for it.
local function classify(itemData)
    local facts = { area = "?", itemType = "?", category = "?", tags = "" }

    local ok, record = pcall(function()
        return RPGManager.GetItemRecord(itemData:GetID())
    end)

    if not ok or record == nil then
        return facts
    end

    local function read(field, fn)
        local readOk, value = pcall(fn)
        if readOk and value ~= nil then
            facts[field] = tostring(value)
        end
    end

    read("area", function() return record:EquipArea():Type() end)
    read("itemType", function() return record:ItemType():Type() end)
    read("category", function() return record:ItemCategory():Type() end)

    local tagsOk, tags = pcall(function()
        return record:Tags()
    end)

    if tagsOk and tags ~= nil then
        local names = {}
        for _, tag in ipairs(tags) do
            names[#names + 1] = tostring(tag.value or tag)
        end
        facts.tags = table.concat(names, "+")
    end

    return facts
end

local EMPTY_FACTS = { area = "?", itemType = "?", category = "?", tags = "" }

local function carryCapacity(player)
    local ok, value = pcall(function()
        return Game.GetStatsSystem():GetStatValue(player:GetEntityID(), gamedataStatType.CarryCapacity)
    end)

    if ok and type(value) == "number" then
        return value
    end

    return nil
end

-- An equipped item is in the list like everything else, and deleting the weapon
-- in the player's hands would be its own kind of accident.
local function isEquipped(player, itemData)
    local ok, slotted = pcall(function()
        return Game.GetTransactionSystem():IsSlotted(player, itemData:GetID())
    end)

    return ok and slotted == true
end

-- The shared walk over the player's inventory. Returns a list of plain tables so
-- that neither caller has to touch a game handle twice.
-- Classification is only needed by the dump; the cleanup preview runs every
-- frame the overlay is open and must not pay for it.
local function survey(classified)
    local player = State.GetPlayer()
    if player == nil then
        Log.Warn("inventory: no player")
        return nil, nil
    end

    local ok, items = pcall(function()
        local _, list = Game.GetTransactionSystem():GetItemList(player)
        return list
    end)

    if not ok or items == nil then
        Log.Warn("inventory: could not read the item list: " .. tostring(items))
        return nil, nil
    end

    local rows = {}

    for _, itemData in ipairs(items) do
        local quantity = 1
        local quantityOk, value = pcall(function()
            return itemData:GetQuantity()
        end)
        if quantityOk and type(value) == "number" and value > 0 then
            quantity = value
        end

        local facts = classified and classify(itemData) or EMPTY_FACTS

        rows[#rows + 1] = {
            item = itemData,
            name = nameOf(itemData),
            quantity = quantity,
            weight = weightOf(itemData),
            area = facts.area,
            itemType = facts.itemType,
            category = facts.category,
            tags = facts.tags,
            -- Deliberately the narrow test, not the loot filter: this flag is
            -- what the delete button acts on.
            restricted = Scanner.IsStuckInInventory(itemData) == true,
            equipped = isEquipped(player, itemData),
        }
    end

    -- Heaviest first: whatever is eating the carry limit should be the first
    -- thing read, and unknown weights sort to the end rather than to zero.
    table.sort(rows, function(a, b)
        local left = a.weight or -1
        local right = b.weight or -1
        if left == right then
            return a.name < b.name
        end
        return left > right
    end)

    return rows, player
end

-- Returns the number of entries written, so the caller can say something useful
-- without reaching into the log.
function Audit.DumpInventory()
    Audit.InvalidateStuckCache()

    local rows, player = survey(true)
    if rows == nil then
        return 0
    end

    local knownWeight = 0.0
    local unknownWeights = 0
    local stuckWeight = 0.0
    local stuck = 0

    for _, row in ipairs(rows) do
        if row.weight ~= nil then
            knownWeight = knownWeight + (row.weight * row.quantity)
        else
            unknownWeights = unknownWeights + 1
        end

        if row.restricted and not row.equipped then
            stuck = stuck + 1
            stuckWeight = stuckWeight + ((row.weight or 0.0) * row.quantity)
        end
    end

    local capacity = carryCapacity(player)

    Log.Info(string.format("inventory dump: %d entries, %.1f known weight%s%s",
        #rows,
        knownWeight,
        capacity and string.format(", carry capacity %.0f", capacity) or "",
        unknownWeights > 0 and string.format(", %d entries of unknown weight", unknownWeights) or ""))

    for _, row in ipairs(rows) do
        Log.Info(string.format("  %s%-8s x%-5d %s [area=%s type=%s cat=%s tags=%s]%s",
            row.restricted and "!! " or "   ",
            row.weight and string.format("%.2f", row.weight) or "?",
            row.quantity,
            row.name,
            row.area,
            row.itemType,
            row.category,
            row.tags ~= "" and row.tags or "-",
            row.equipped and " EQUIPPED" or ""))
    end

    if stuck > 0 then
        Log.Warn(string.format(
            "inventory dump: %d entries (%.1f weight) do not belong in a backpack; "
            .. "use 'Remove stuck items' to delete them", stuck, stuckWeight))
    end

    return #rows
end

-- Recomputed at most this often: the settings window asks on every frame it is
-- drawn, and a full walk of a 200-item inventory is not a per-frame cost.
local STUCK_CACHE_SECONDS = 2.0

local _stuckCache = nil
local _stuckCacheStamp = nil

function Audit.InvalidateStuckCache()
    _stuckCache = nil
    _stuckCacheStamp = nil
end

local function clock()
    local ok, now = pcall(os.clock)
    if ok and type(now) == "number" then
        return now
    end
    return nil
end

-- What the cleanup would delete, without deleting anything.
function Audit.FindStuckItems()
    local now = clock()

    if _stuckCache ~= nil and now ~= nil and _stuckCacheStamp ~= nil
        and (now - _stuckCacheStamp) < STUCK_CACHE_SECONDS then
        return _stuckCache.items, _stuckCache.weight
    end

    local rows = survey(false)
    if rows == nil then
        return {}, 0.0
    end

    local stuck = {}
    local weight = 0.0

    for _, row in ipairs(rows) do
        -- Never the item in the player's hands, whatever it is.
        if row.restricted and not row.equipped then
            stuck[#stuck + 1] = row
            weight = weight + ((row.weight or 0.0) * row.quantity)
        end
    end

    _stuckCache = { items = stuck, weight = weight }
    _stuckCacheStamp = now

    return stuck, weight
end

-- Deletes them. These are items the game will not show, will not let go of and
-- will not let the player drop, so removal is the only way out; everything
-- removed is named in the log first, in case the judgement was wrong.
function Audit.RemoveStuckItems()
    local player = State.GetPlayer()
    if player == nil then
        Log.Warn("cleanup: no player")
        return 0, 0.0
    end

    Audit.InvalidateStuckCache()
    local stuck, weight = Audit.FindStuckItems()

    if #stuck == 0 then
        Log.Info("cleanup: nothing to remove")
        return 0, 0.0
    end

    local removed = 0
    local removedWeight = 0.0

    for _, row in ipairs(stuck) do
        local ok, err = pcall(function()
            Game.GetTransactionSystem():RemoveItem(player, row.item:GetID(), row.quantity)
        end)

        if ok then
            removed = removed + 1
            removedWeight = removedWeight + ((row.weight or 0.0) * row.quantity)
            Log.Info(string.format("cleanup: removed %s x%d (%.1f weight)",
                row.name, row.quantity, (row.weight or 0.0) * row.quantity))
        else
            Log.Warn(string.format("cleanup: could not remove %s: %s", row.name, tostring(err)))
        end
    end

    Log.Info(string.format("cleanup: %d of %d entries removed, %.1f weight freed of %.1f found",
        removed, #stuck, removedWeight, weight))

    -- The handles just used are stale now.
    Audit.InvalidateStuckCache()

    return removed, removedWeight
end

return Audit
