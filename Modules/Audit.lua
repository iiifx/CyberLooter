-- On-demand inventory dump.
--
-- The backpack UI is a view, not the inventory: an item the interface has no
-- place for is simply not drawn, while its weight still counts against the carry
-- limit. That is not a hypothetical - the heavy weapons this mod used to take by
-- mistake behave exactly that way, invisible in the backpack and impossible to
-- drop from it.
--
-- This asks the transaction system instead, which is the same source the mod
-- loots through, and writes everything it holds to the log.

local Audit = {}

local Log, State

function Audit.Init(deps)
    Log = deps.Log
    State = deps.State
end

local function nameOf(itemData)
    local ok, name = pcall(function()
        return TDBID.ToStringDEBUG(ItemID.GetTDBID(itemData:GetID()))
    end)

    if ok and name ~= nil and name ~= "" then
        return name
    end

    local fallbackOk, fallback = pcall(function()
        return tostring(itemData:GetID().id)
    end)

    return (fallbackOk and fallback) or "?"
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

local function areaOf(itemData)
    local ok, area = pcall(function()
        local record = RPGManager.GetItemRecord(itemData:GetID())
        if record == nil then
            return nil
        end

        local equipArea = record:EquipArea()
        if equipArea == nil then
            return nil
        end

        return tostring(equipArea:Type())
    end)

    if ok and area ~= nil then
        return area
    end

    return "?"
end

local function carryCapacity(player)
    local ok, value = pcall(function()
        return Game.GetStatsSystem():GetStatValue(player:GetEntityID(), gamedataStatType.CarryCapacity)
    end)

    if ok and type(value) == "number" then
        return value
    end

    return nil
end

-- Returns the number of entries written, so the caller can say something useful
-- without reaching into the log.
function Audit.DumpInventory()
    local player = State.GetPlayer()
    if player == nil then
        Log.Warn("inventory dump: no player")
        return 0
    end

    local ok, items = pcall(function()
        local _, list = Game.GetTransactionSystem():GetItemList(player)
        return list
    end)

    if not ok or items == nil then
        Log.Warn("inventory dump: could not read the item list: " .. tostring(items))
        return 0
    end

    local rows = {}
    local knownWeight = 0.0
    local unknownWeights = 0

    for _, itemData in ipairs(items) do
        local quantity = 1
        local quantityOk, value = pcall(function()
            return itemData:GetQuantity()
        end)
        if quantityOk and type(value) == "number" then
            quantity = value
        end

        local weight = weightOf(itemData)
        if weight ~= nil then
            knownWeight = knownWeight + (weight * quantity)
        else
            unknownWeights = unknownWeights + 1
        end

        rows[#rows + 1] = {
            name = nameOf(itemData),
            quantity = quantity,
            weight = weight,
            area = areaOf(itemData),
            -- The one category known to be both invisible and heavy.
            suspect = false,
        }
    end

    for _, row in ipairs(rows) do
        row.suspect = row.area:find("WeaponHeavy") ~= nil
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

    local capacity = carryCapacity(player)

    Log.Info(string.format("inventory dump: %d entries, %.1f known weight%s%s",
        #rows,
        knownWeight,
        capacity and string.format(", carry capacity %.0f", capacity) or "",
        unknownWeights > 0 and string.format(", %d entries of unknown weight", unknownWeights) or ""))

    for _, row in ipairs(rows) do
        Log.Info(string.format("  %s%-8s x%-5d %s [%s]",
            row.suspect and "!! " or "   ",
            row.weight and string.format("%.2f", row.weight) or "?",
            row.quantity,
            row.name,
            row.area))
    end

    local suspects = 0
    for _, row in ipairs(rows) do
        if row.suspect then
            suspects = suspects + 1
        end
    end

    if suspects > 0 then
        Log.Warn(string.format(
            "inventory dump: %d hand-carried weapon(s) are sitting in the inventory; "
            .. "these do not appear in the backpack UI and cannot be dropped from it", suspects))
    end

    return #rows
end

return Audit
