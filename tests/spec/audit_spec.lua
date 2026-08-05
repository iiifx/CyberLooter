-- The inventory dump, which exists because the backpack UI does not show
-- everything the inventory actually holds.

local Stub = require("tests/support/game.lua")

local function setup()
    local world = Stub.install()
    local log = Stub.log()

    local Audit = Stub.load("Modules/Audit.lua")
    Audit.Init({ Log = log, State = { GetPlayer = function() return world.player end } })

    return Audit, world, log
end

describe("Audit.DumpInventory", function()
    it("writes one line per item plus a summary", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "pistol", weight = 3.0 }),
            Stub.item({ name = "shard", weight = 0.0 }),
        }

        eq(Audit.DumpInventory(), 2)
        contains(log.text(), "inventory dump: 2 entries")
        contains(log.text(), "Items.pistol")
        contains(log.text(), "Items.shard")
    end)

    it("multiplies weight by the size of the stack", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.item({ name = "ammo", weight = 0.5, quantity = 10 }) }

        Audit.DumpInventory()
        contains(log.text(), "5.0 known weight")
    end)

    it("reports the carry capacity next to the weight", function()
        local Audit, world, log = setup()
        world.carryCapacity = 200.0
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        contains(log.text(), "carry capacity 200")
    end)

    it("calls out a hand-carried weapon sitting in the inventory", function()
        -- This is the whole reason the dump exists: such a weapon is invisible in
        -- the backpack, cannot be dropped from it, and still costs carry weight.
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "shard", weight = 0.0 }),
            Stub.heavyWeapon({ weight = 30.0 }),
        }

        Audit.DumpInventory()
        contains(log.text(), "!!")
        contains(log.text(), "1 hand-carried weapon(s) are sitting in the inventory")
    end)

    it("says nothing alarming when the inventory is clean", function()
        local Audit, world, log = setup()
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        isNil(log.find("hand-carried weapon(s) are sitting"))
    end)

    it("lists the heaviest item first", function()
        local Audit, world, log = setup()
        world.player.__items = {
            Stub.item({ name = "feather", weight = 0.1 }),
            Stub.item({ name = "anvil", weight = 40.0 }),
        }

        Audit.DumpInventory()
        local text = log.text()
        isTrue(text:find("Items.anvil", 1, true) < text:find("Items.feather", 1, true),
            "the thing eating the carry limit should be the first thing read")
    end)

    it("reports an unknown weight as unknown rather than as zero", function()
        -- Zero is the exact claim under suspicion, so it must never be invented.
        local Audit, world, log = setup()
        world.noItemWeightApi = true
        world.player.__items = { Stub.item({ name = "mystery" }) }

        Audit.DumpInventory()
        contains(log.text(), "1 entries of unknown weight")
        contains(log.text(), "?")
    end)

    it("falls back to the item stat when the weight helper is missing", function()
        local Audit, world, log = setup()
        world.noItemWeightApi = true
        world.player.__items = { Stub.item({ name = "pistol", weight = 3.0 }) }

        Audit.DumpInventory()
        contains(log.text(), "3.0 known weight")
    end)

    it("says so instead of throwing when there is no player", function()
        local Audit, world, log = setup()
        world.player = nil

        eq(Audit.DumpInventory(), 0)
        contains(log.text(), "no player")
    end)
end)
