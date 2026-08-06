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

-- Used in two situations: as a fallback when TransferAllItems moves nothing, and
-- deliberately whenever an object also holds something the mod must not take, so
-- that the rest can still be collected around it.
local function transferItemByItem(holder, player)
    local moved = 0

    local ok, err = pcall(function()
        local transactionSystem = Game.GetTransactionSystem()
        local _, items = transactionSystem:GetItemList(holder)
        if items == nil then
            return
        end

        for _, itemData in ipairs(items) do
            -- Hand-carried weapons and quest loot are left exactly where they are.
            if not Scanner.IsSkippedItem(itemData) then
                local itemID = itemData:GetID()
                local quantity = itemData:GetQuantity()
                if quantity == nil or quantity < 1 then
                    quantity = 1
                end

                -- Strictly true only: a nil return means "unknown", and counting
                -- that as success would let the fallback report loot it never moved.
                local transferred = transactionSystem:TransferItem(holder, player, itemID, quantity)
                if transferred == true then
                    moved = moved + 1
                end
            end
        end
    end)

    if not ok then
        Log.Warn("item-by-item fallback failed: " .. tostring(err))
    end

    return moved
end

-- Returns: success, method, movedStacks (nil = unknown, use the scanned count).
local function lootOne(entry, player)
    local holder = entry.holder
    local before = totalQuantity(holder)

    -- Nothing there any more: the scan cache is up to 0.3s old, so the object may
    -- have been emptied in the meantime. Not a success, not a failure.
    if before == 0 then
        return false, "already empty", 0
    end

    -- Objects holding something the sweep must not take, alongside ordinary loot,
    -- cannot go through the bulk transfer: it would move the quest item or the
    -- hand-carried weapon too.
    if entry.restricted then
        local moved = transferItemByItem(holder, player)
        if moved > 0 then
            return true, "itemByItem(restricted)", moved
        end
        return false, "nothing movable", 0
    end

    local ok, err = pcall(function()
        Game.GetTransactionSystem():TransferAllItems(holder, player)
    end)

    if not ok then
        Log.Warn("TransferAllItems failed: " .. tostring(err))
    end

    local after = totalQuantity(holder)

    -- Success is measured by the object actually emptying rather than by the call
    -- returning, because that is the only honest signal available. A quantity of
    -- -1 means the question could not be asked at all - typically the object has
    -- already despawned after being emptied, so an error-free call is taken at
    -- its word rather than being retried against a dead handle.
    if before > 0 and after >= 0 and after < before then
        return true, "transferAll", nil
    end

    if after == -1 then
        if not ok then
            return false, "handle lost", 0
        end

        -- Taking the call at its word only makes sense if the object was known to
        -- hold something a moment ago. When the count was already unreadable
        -- beforehand, nothing has been observed at either end and there is no
        -- evidence to report success on, so the fallback below gets its turn.
        if before > 0 then
            return true, "transferAll(unverified)", nil
        end
    end

    -- Starting count unknown, but the object is now demonstrably empty.
    if before == -1 and after == 0 then
        return true, "transferAll", nil
    end

    -- Everything else means items are still sitting there, so the fallback gets
    -- its turn. "before unknown, after non-zero" deliberately lands here: an
    -- unreadable starting count is no excuse to claim success while loot is
    -- visibly left behind.
    local moved = transferItemByItem(holder, player)
    if moved > 0 then
        Log.DebugThrottled("loot.fallback", 10.0,
            "TransferAllItems moved nothing, item-by-item moved " .. tostring(moved))
        return true, "itemByItem", moved
    end

    return false, "nothing moved", 0
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
    local processed = 0
    local attempted = 0
    local succeeded = 0
    local skipped = 0
    local stacks = 0
    local methods = {}

    for _, entry in ipairs(objects) do
        if processed >= limit then
            Log.Info(string.format(
                "sweep hit the %d object limit, %d left for the next hold", limit, #objects - processed))
            break
        end

        processed = processed + 1

        local ok, method, movedStacks = lootOne(entry, player)
        methods[method] = (methods[method] or 0) + 1

        if method == "already empty" then
            -- Emptied by something else while the scan cache was still warm.
            -- Counting it as a failed attempt would misreport a healthy sweep.
            skipped = skipped + 1
        else
            attempted = attempted + 1
            if ok then
                succeeded = succeeded + 1
                -- The fallback path knows exactly how much it moved; the primary
                -- path does not, so the scanned stack count stands in for it and
                -- is therefore an estimate.
                stacks = stacks + (movedStacks or entry.stacks)
            end
        end
    end

    local detail = {}
    for method, count in pairs(methods) do
        detail[#detail + 1] = method .. "=" .. tostring(count)
    end

    if skipped > 0 then
        detail[#detail + 1] = "skipped=" .. tostring(skipped)
    end

    Looter.lastSweep = string.format("%d/%d objects, ~%d stacks", succeeded, attempted, stacks)
    Log.Info(string.format("sweep: %d/%d objects, ~%d stacks [%s]",
        succeeded, attempted, stacks, table.concat(detail, " ")))

    Scanner.Invalidate()

    return succeeded
end

return Looter
