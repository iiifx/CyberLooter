-- Moving the items into the player's inventory.
--
-- The primary path is exactly what the game itself runs when F is pressed on a
-- corpse (scriptedPuppet.swift:2899):
--     TransactionSystem.TransferAllItems(source, player)
-- Everything else (marker, highlight, HUD entry, "empty" effect) is driven by
-- inventory events and therefore happens on its own.

local Looter = {}

local Log, Config, Scanner, State

Looter.lastSweep = "none yet"

local function totalQuantity(holder)
    local ok, quantity = pcall(function()
        return Game.GetTransactionSystem():GetTotalItemQuantity(holder)
    end)

    if not ok or quantity == nil then
        return -1
    end

    return quantity
end

-- Fallback for the case where TransferAllItems turns out not to work on some
-- class of object. Slower and less faithful, so it is only used if the primary
-- path visibly moved nothing.
local function transferItemByItem(holder, player)
    local moved = 0

    local ok, err = pcall(function()
        local transactionSystem = Game.GetTransactionSystem()
        local _, items = transactionSystem:GetItemList(holder)
        if items == nil then
            return
        end

        for _, itemData in ipairs(items) do
            local itemID = itemData:GetID()
            local quantity = itemData:GetQuantity()
            if quantity == nil or quantity < 1 then
                quantity = 1
            end

            local transferred = transactionSystem:TransferItem(holder, player, itemID, quantity)
            if transferred ~= false then
                moved = moved + 1
            end
        end
    end)

    if not ok then
        Log.Warn("item-by-item fallback failed: " .. tostring(err))
    end

    return moved
end

local function lootOne(entry, player)
    local holder = entry.holder
    local before = totalQuantity(holder)

    local ok, err = pcall(function()
        Game.GetTransactionSystem():TransferAllItems(holder, player)
    end)

    if not ok then
        Log.Warn("TransferAllItems failed: " .. tostring(err))
    end

    local after = totalQuantity(holder)

    -- Success is measured by the object actually emptying, not by the call
    -- returning: that is the only honest signal available here.
    if after == 0 or (before > 0 and after >= 0 and after < before) then
        return true, "transferAll"
    end

    local moved = transferItemByItem(holder, player)
    if moved > 0 then
        Log.DebugThrottled("loot.fallback", 10.0,
            "TransferAllItems moved nothing, item-by-item moved " .. tostring(moved))
        return true, "itemByItem"
    end

    return false, "nothing moved"
end

function Looter.Init(deps)
    Log = deps.Log
    Config = deps.Config
    Scanner = deps.Scanner
    State = deps.State
end

-- One sweep = one key hold. Returns how many objects were emptied.
function Looter.Sweep()
    local player = State.GetPlayer()
    if player == nil then
        return 0
    end

    local objects = Scanner.Get()
    if #objects == 0 then
        Looter.lastSweep = "nothing in radius"
        return 0
    end

    local limit = Config.values.maxObjectsPerSweep
    local attempted = 0
    local succeeded = 0
    local stacks = 0
    local methods = {}

    for _, entry in ipairs(objects) do
        if attempted >= limit then
            Log.Info(string.format(
                "sweep hit the %d object limit, %d left for the next hold", limit, #objects - attempted))
            break
        end

        attempted = attempted + 1

        local ok, method = lootOne(entry, player)
        if ok then
            succeeded = succeeded + 1
            stacks = stacks + entry.stacks
            methods[method] = (methods[method] or 0) + 1
        else
            methods[method] = (methods[method] or 0) + 1
        end
    end

    local detail = {}
    for method, count in pairs(methods) do
        detail[#detail + 1] = method .. "=" .. tostring(count)
    end

    Looter.lastSweep = string.format("%d/%d objects, %d stacks", succeeded, attempted, stacks)
    Log.Info(string.format("sweep: %d/%d objects, %d stacks [%s]",
        succeeded, attempted, stacks, table.concat(detail, " ")))

    Scanner.Invalidate()

    return succeeded
end

return Looter
